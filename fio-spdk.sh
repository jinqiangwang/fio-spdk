#!/bin/bash

usage="invalid parameters provided.\
\nexample:\n $0 [-t nvme|spdk] -d \"nvme0n1 nvme1n1\" [-c \"0-7 8-15\" | -n \"0 1\"] [-j job_cfg_file]\n\
\t -t: nvme|spdk, test using nvme driver or spdk. default is nvme. optional\n\
\t -d: drive list. mandatory option\n\
\t -c: cpu core bind list. bind list is corresponding to drive list. optional\n\
\t -n: numa node bind list. -n takes precendence when both -c and -n are used. optional\n\
\t -j: job config file. default config file is \"job_cfg_common\". optional\n\"
\t -l: record fio IOPS/BW logs. enabling this may cause IOPS/BW dropping on slow CPUs"

export my_dir="$( cd "$( dirname "$0"  )" && pwd  )"
timestamp=`date +%Y%m%d_%H%M%S`
output_dir=${my_dir}/${timestamp}

# default values
export type=nvme
disks=""
numa_list=""    # numa list to bind; if both -n & -c are used, numa list takes precendence
core_list=""    # cpu core list to bind
jobcfg=job_cfg_common
record_fio_log=0 # by default do not record fio IOPS/BW logs

while getopts "d:c:j:n:t:l" opt
do
    case $opt in 
    t)
        export type=$OPTARG
        ;;
    d)
        disks=($OPTARG)
        ;;
    c)
        core_list="$OPTARG"
        ;;
    n)
        numa_list="$OPTARG"
        ;;
    j)
        jobcfg="$OPTARG"
        ;;
    l)
        record_fio_log=1
        ;;
    *)
        echo -e ${usage}
        exit 1
    esac
done

if [[ "${type}" != "spdk" ]] && [[ "${type}" != "nvme" ]]
then
    echo -e ${usage}
    exit 1
fi

if [ -z "${disks}" ]
then
    echo -e ${usage}
    exit 1
fi

cpu_bind=""
if  [ ! -z "${numa_list}" ]
then 
    cpu_bind="--numa_cpu_nodes="
    bind_list=(${numa_list})
elif [ ! -z "${core_list}" ]
then
    cpu_bind="--cpus_allowed="
    bind_list=(${core_list})
fi

if [ ! -z "${cpu_bind}" ] && [ ${#disks[@]} -gt ${#bind_list[@]} ]
then
    echo "disk count is greater than CPU/NUMA bind opt count, please check parameters"
    exit 1
fi

source ${my_dir}/helper/functions
source ${my_dir}/helper/func_spdk
source ${my_dir}/${jobcfg}
source ${my_dir}/jobs/common.fio

os_str=$(get_os_str)
if [ -z "${os_str}" ]; then
    echo "Warning: current OS is not supported. Check if your OS is on below list:\n\tCentOS 7\n\tCentOS 8\n\topenEuler 20.03\n\tCTYunOS 2.0.1\n "
    if [ -z "${fio_cmd}" ]; then
        echo "you may append fio_cmd=fio before $0 to force it ro run."
        echo "example:"
        echo "    fio_cmd=/usr/bin/fio ./fio-spdk.sh -d nvme2n1"
        exit 3;
    fi
fi

spdk_dir="${my_dir}/bin/${os_str}/spdk"
fio_dir="${my_dir}/bin/${os_str}/fio"
fio_cmd=${fio_cmd-"${fio_dir}/fio"}
ld_preload=""
filename_format="/dev/%s"
nvme_dev_info=$(${my_dir}/tools/nvme_dev.sh)

if [ ! -d "${output_dir}" ]; then mkdir -p ${output_dir}; fi
iostat_dir=${output_dir}/iostat
result_dir=${output_dir}/result
drvinfo_dir=${output_dir}/drvinfo
mkdir -p ${iostat_dir}
mkdir -p ${result_dir}
mkdir -p ${drvinfo_dir}
if [ ${record_fio_log} -ne 0 ]; then
    iolog_dir=${output_dir}/io_logs
    mkdir -p ${iolog_dir}
fi

echo -e "$0 $@\n"        > ${output_dir}/sysinfo.log
echo "${nvme_dev_info}" >> ${output_dir}/sysinfo.log
collect_sys_info        >> ${output_dir}/sysinfo.log

test_disks=""

verify_workloads ${my_dir}/jobs
if [ $? -ne 0 ]; then
    echo "failed to verify workload config, exit"
    exit 1;
fi

for disk in ${disks[@]}
do
    if [ ! -b /dev/${disk} ]; then
        echo "${disk} does not exist, please check name"
        continue
    fi

    nvme_has_mnt_pnt ${disk}
    if [ $? -ne 0 ]; then
        echo "${disk} is mounted or contains file system, skipping it for test"
        continue
    fi
    test_disks=(${test_disks[@]} ${disk})
    ${my_dir}/tools/hotplug ${disk} > ${drvinfo_dir}/${disk}_hotplug.log
    ${my_dir}/tools/irqlist ${disk} > ${drvinfo_dir}/${disk}_irqlist.log
    collect_drv_info ${disk}        > ${drvinfo_dir}/${disk}_1.info
done

disks=(${test_disks[@]})

if [ -z "${disks}" ]
then
    echo "no valid nvme drive for testing, please check provided parameters"
    exit 1
fi

if [ "${type}" == "spdk" ]
then
    # prepare spdk environment
    export spdk_white_list=""
    spdk_disks=""
    for disk in ${disks[@]}
    do
        export spdk_white_list="${spdk_white_list} $(nvme2busid ${disk})"
        spdk_disks=(${spdk_disks[@]} $(nvme2busid_spdk ${disk}))
    done
    
    setup_spdk "${spdk_dir}" "${spdk_white_list}" 
    if [ $? -ne 0 ]
    then
        echo "setup spdk failed, revert ..."
        reset_spdk "${spdk_dir}"
        echo "revert done"
        exit 2
    fi
    ld_preload="${spdk_dir}/build/fio/spdk_nvme "
    filename_format="trtype=PCIe traddr=%s ns=1 "
    disks=(${spdk_disks[@]})
    export ioengine=spdk
    echo "start fio test using spdk"
    echo "on drives: [${disks[@]}]"
else
    echo "start fio test using conventional nvme driver"
    echo "on drives: [${disks[@]}]"
fi

bind_cnt=0
if [ ! -z ${bind_list} ]
then
    bind_cnt=${#bind_list[@]}
fi

for workload in ${workloads[@]}
do
    fio_pid_list=""
    iostat_pid_list=""
    i=0

    workload_desc=($(prep_workload ${workload}))
    workload_file=${workload_desc[0]}   # fio config file name
    workload_name=${workload_desc[1]}   # description name with details
    bs=${workload_desc[2]}              # bs
    numjobs=${workload_desc[3]}         # numjobs
    iodepth=${workload_desc[4]}         # iodepth
    echo "${workload_desc} ${workload_name}-${bs}+j${numjobs}+qd${iodepth}"

    if [ "${type}" != "spdk" ]; then
        iostat -dxmct 1 ${disks[@]} > ${iostat_dir}/${workload_name}.iostat &
        export iostat_pid=$!
    fi

    for disk in ${disks[@]}; do
        cpu_bind_opt=""
        if [ ! -z "${cpu_bind}" ]; then
            cpu_bind_opt="${cpu_bind}${bind_list[$i]}"
        fi

        if [ -f ${result_dir}/${disk}_${workload_name}.fio ]; then 
            workload_name="${workload_name}_`date +%Y%m%d_%H%M%S`"
        fi

        export output_name=${iolog_dir}/${disk}_${workload_name}
        
        fio_log_opt=""
        if [ ${record_fio_log} -ne 0 ]; then
            fio_log_opt="--log_avg_msec=1000 \
                         --per_job_logs=0 \
                         --write_bw_log=$output_name} 
                         --write_iops_log=${output_name} \
                         --write_lat_log=${output_name}"
        fi

        command_line="LD_PRELOAD=${ld_preload} \
            bs=${bs} numjobs=${numjobs} iodepth=${iodepth} \
            ${fio_cmd} --filename=\"$(printf \"${filename_format}\" ${disk})\" \
            ${cpu_bind_opt} \
            ${fio_log_opt} \
            ${random_map_opts} \
            --output=${result_dir}/${disk}_${workload_name}.fio \
            ${my_dir}/jobs/${workload_file}.fio &"

        echo ${command_line} >> ${output_dir}/${disk}_cmdline.log

        LD_PRELOAD=${ld_preload} \
        bs=${bs} numjobs=${numjobs} iodepth=${iodepth} \
        ${fio_cmd} --filename="$(printf "${filename_format}" ${disk})" \
        ${cpu_bind_opt} \
        ${fio_log_opt} \
        ${random_map_opts} \
        --output=${result_dir}/${disk}_${workload_name}.fio \
        ${my_dir}/jobs/${workload_file}.fio &
        fio_pid_list="${fio_pid_list} $!"
        i=$(($i+1))
    done

    wait ${fio_pid_list}
    if [ ! -z "${iostat_pid}" ]; then
        kill -9 ${iostat_pid}
    fi
    sync
done

reset_spdk "${spdk_dir}" "${spdk_white_list}"

# test_disks are nvme drive while disk can be BDFs
for disk in ${test_disks[@]}
do
    collect_drv_info ${disk} > ${drvinfo_dir}/${disk}_2.info
done

if [ "${type}" == "nvme" ]; then
    for disk in ${disks[@]}; do
        iostat_to_csv_1 ${iostat_dir} ${disk}
    done
fi

for disk in ${disks[@]}
do
    fio_to_csv ${result_dir} ${disk}
done

consolidate_summary ${result_dir} ${output_dir}
