#!/bin/bash

usage="invalid parameters detected.\
\nexample:\n $0 [-f ext4|xfs] -d \"nvme0n1 nvme1n1\" [-c \"0-7 8-15\" | -n \"0 1\"] [-j job_cfg_file]\n\
\t -t: file system type, deafult to ext4, available optsions [ext4|xfs]\n\
\t -d: drive list. mandatory option\n\
\t -c: cpu core bind list. bind list is corresponding to drive list. optional\n\
\t -n: numa node bind list. -n takes precendence when both -c and -n are used. optional\n\
\t -j: job config file. default config file is \"job_cfg_common\". optional\n\
\t -l: record fio IOPS/BW logs. enabling this may cause IOPS/BW dropping on slow CPUs\
\t -r: unmout drives mount point after test. file system will remain and you need to maunually clean them up"

export my_dir="$( cd "$( dirname "$0"  )" && pwd  )"
timestamp=`date +%Y%m%d_%H%M%S`
output_dir=${my_dir}/${timestamp}

# default values
export type=nvme
export disks=""
fs_type=""
numa_list=""     # numa list to bind; if both -n & -c are used, numa list takes precendence
core_list=""     # cpu core list to bind
jobcfg=job_cfg_common
record_fio_log=0 # by default do not record fio IOPS/BW logs
export remove_mntpoint=0
export size_factor=${size_factor-0.9}

while getopts "d:c:j:n:t:lr" opt
do
    case $opt in 
    t)
        export fs_type=$OPTARG
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
    r)
        export remove_mntpoint=1
        ;;
    *)
        echo -e ${usage}
        exit 1
    esac
done

case ${fs_type} in
    ext4|xfs)
        ;;
    *)
        echo -e ${usage}
        ;;
esac

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

if [ -z ${jobcfg} ] || [ ! -f ${jobcfg} ]; then echo "please specify job cfg file"; exit 1; fi

source ${my_dir}/${jobcfg}
source ${my_dir}/helper/functions
source ${my_dir}/helper/func_spdk
source ${my_dir}/jobs_fs/common.fio

os_str=$(get_os_str)
if [ -z "${os_str}" ]; then
    echo "Warning: current OS is not supported. Check if your OS is on below list:\n\tCentOS 7\n\tCentOS 8\n\topenEuler 20.03\n\tCTYunOS 2.0.1\n "
    if [ -z "${fio_cmd}" ]; then
        echo "you may append fio_cmd=fio before $0 to force it ro run."
        echo "example:"
        echo "    fio_cmd=/usr/bin/fio $0 -d nvme2n1"
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

verify_workloads ${my_dir}/jobs_fs
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

export disks=(${test_disks[@]})

if [ -z "${disks}" ]
then
    echo "no valid nvme drive for testing, please check provided parameters"
    exit 1
fi

echo "start fio test using conventional nvme driver, file system is: ${fs_type}"
echo "on drives: [${disks[@]}]"

test_data_dir=${my_dir}/test_data
if [ ! -d ${test_data_dir} ]; then
    mkdir ${test_data_dir} -p
fi

echo unmount existing mount points ...
for disk in ${disks[@]}; do
    for((;;)); do
        if [ ! -z "$(df | grep ${disk})" ]; then
            umount /dev/${disk}
        else
            break
        fi
    done
    # set -x
    mkfs -t ${fs_type} -f /dev/${disk}
    if [ ! -d ${test_data_dir}/${disk} ]; then mkdir ${test_data_dir}/${disk} -p; fi
    mount /dev/${disk} ${test_data_dir}/${disk}
    mntpoint=$(mountpoint -d ${test_data_dir}/${disk})
    if [ -z "${mntpoint}" ]; then
        echo "failed to mount /dev/${disk} to ${test_data_dir}/${disk}"
        exit 1
    fi
    # set +x
done

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

    iostat -dxmct 1 ${disks[@]} > ${iostat_dir}/${workload_name}.iostat &
    export iostat_pid=$!

    for disk in ${disks[@]}; do
        disk_size=$(lsblk -b -o SIZE /dev/${disk} | grep -v SIZE)
        file_size=$(echo "${disk_size} ${numjobs} ${size_factor}" | awk '{printf "%d\n", ($1/$2)*$3}')
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

        if [ ! -d ${test_data_dir}/${disk}/datadir ]; then mkdir ${test_data_dir}/${disk}/datadir; fi
        command_line="LD_PRELOAD=${ld_preload} \
            bs=${bs} numjobs=${numjobs} iodepth=${iodepth} \
            ${fio_cmd} --directory=${test_data_dir}/${disk}/datadir \
            --filename_format=${job_name}_${jobnum}_${filenum} \
            --size=${file_size}B \
            ${cpu_bind_opt} \
            ${fio_log_opt} \
            ${random_map_opts} \
            --output=${result_dir}/${disk}_${workload_name}.fio \
            ${my_dir}/jobs_fs/${workload_file}.fio &"

        echo ${command_line} >> ${output_dir}/${disk}_cmdline.log

        LD_PRELOAD=${ld_preload} \
        bs=${bs} numjobs=${numjobs} iodepth=${iodepth} \
        ${fio_cmd} --directory=${test_data_dir}/${disk}/datadir \
        --filename_format=${job_name}_${jobnum}_${filenum} \
        --size=${file_size}B \
        ${cpu_bind_opt} \
        ${fio_log_opt} \
        ${random_map_opts} \
        --output=${result_dir}/${disk}_${workload_name}.fio \
        ${my_dir}/jobs_fs/${workload_file}.fio &
        fio_pid_list="${fio_pid_list} $!"
        i=$(($i+1))
    done

    wait ${fio_pid_list}
    if [ ! -z "${iostat_pid}" ]; then
        kill -9 ${iostat_pid}
    fi
    sync
done

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
    if [ ${remove_mntpoint} -ne 0 ]; then
        for i in {1..10}; do
            umount /dev/${disk} -f
            ret=$?
            if [ ${ret} -ne 0 ] && [ ${ret} -ne 32 ]; then sleep 0.2; else break; fi
        done
        wipefs -a /dev/${disk}
    fi
done

consolidate_summary ${result_dir} ${output_dir}
