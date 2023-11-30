#!/usr/bin/bash
#2022-09-14

usage="invalid parameters provided. \nexample:\n\t $0 -d \"nvme0n1 nvme1n1 nvme2n1\" -m(MPS) \"128 256 512 \" [-r(MRRS) \"512 2048 4096\"]"

while getopts "d:m:r:" opt; do
    case $opt in
    d)
        dev=($OPTARG)
        ;;
    m)
        mps=($OPTARG)
        ;;
    r)
        mrrs=($OPTARG)
        ;;
    *)
        echo -e ${usage}
        exit 1
        ;;
    esac
done

if [ -z "${dev}" ]
then
     echo -e ${usage}
     exit 1
fi

if [[ "${mps}" != "128" ]] && [[ "${mps}" != "256" ]] && [[ "${mps}" != "512" ]] && [[ "${mps}" != "2048" ]] && [[ "${mps}" != "4096" ]]
then
     echo -e ${usage}
     exit 1
fi
export num=""
export busid1=""
export busid2=""
export busid3=""
export busid4=""
find_busid(){

        export num=$(ls -al /sys/block |grep $disk |awk -F "/" '{print NF-1}' )
        if [[ $num == "9" ]]
        then
            export busid1=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-3)}')
            export busid2=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-4)}')
            export busid3=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-5)}')
            export busid4=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-6)}')
        elif [[ $num == "8" ]]
        then
            export busid1=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-3)}')
            export busid2=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-4)}')
            export busid3=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-5)}')
        elif [[ $num == "7" ]]
        then
            export busid1=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-3)}')
            export busid2=$(ls -al /sys/block |grep $disk |awk -F "/" '{print $(NF-4)}')
        fi

}

set_mps_mrrs(){

        export be_devmrrs=$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max |awk '{print $5}' )
        export be_devmps=$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max |awk '{print $2}' )
        if [ -z "${mrrs}" ]
        then
            echo $busid1 $busid2 $busid3 $busid4
            if [[ $be_devmrrs == "512" ]]
            then
                setmrrs="20"
            elif [[ $be_devmrrs == "2048" ]]
            then
                setmrrs="40"
            elif [[ $be_devmrrs == "4096" ]]
            then
                setmrrs="50"
            fi
        else
            echo $busid1 $busid2 $busid3 $busid4
            if [[ $mrrs == "512" ]]
            then
                setmrrs="20"
            elif [[ $mrrs == "2048" ]]
            then
                setmrrs="40"
            elif [[ $mrrs == "4096" ]]
            then
                setmrrs="50"
            fi
        fi

        if [[ "${mps}" == "128" ]]
        then
            setmps="10"
        elif [[ "${mps}" == "256" ]]
        then
            setmps="20"
        elif [[ "${mps}" == "512" ]]
        then
            setmps="40" 
        elif [[ "${mps}" == "2048" ]]
	then
	    setmps="80"
	elif [[ "${mps}" == "4096" ]]
	then
	    setmps="a0"		    
        fi    
        #echo $num
        if [[ "${num}" == "9" ]]
        then
            setpci -s $busid1 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid2 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid3 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid4 CAP_EXP+08.W=${setmrrs}${setmps}
        elif [[ "${num}" == "8" ]]
        then
            setpci -s $busid1 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid2 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid3 CAP_EXP+08.W=${setmrrs}${setmps}
        elif [[ "${num}" == "7" ]]
        then
            setpci -s $busid1 CAP_EXP+08.W=${setmrrs}${setmps}
            setpci -s $busid2 CAP_EXP+08.W=${setmrrs}${setmps}
        fi
}

for disk in ${dev[@]}
do
   SN=$(nvme list | grep $disk | awk '{print $2}') 
   find_busid
   set_mps_mrrs
   export af_devmrrs=$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max |awk '{print $5}' )
   export af_devmps=$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max |awk '{print $2}' )
   echo $(ls -al /sys/block |grep $disk)
   if [[ "${num}" == "9" ]]
   then
        echo $busid1
        echo "$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid2
        echo "$(lspci -s $busid2 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid3
        echo "$(lspci -s $busid3 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid4
        echo "$(lspci -s $busid4 -vvv  |grep -A2 DevCtl: |grep Max )"
        elif [[ "${num}" == "8" ]]
        then
        echo $busid1
        echo "$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid2
        echo "$(lspci -s $busid2 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid3
        echo "$(lspci -s $busid3 -vvv  |grep -A2 DevCtl: |grep Max )"
        elif [[ "${num}" == "7" ]]
        then
        echo $busid1
        echo "$(lspci -s $busid1 -vvv  |grep -A2 DevCtl: |grep Max )"
        echo $busid2
        echo "$(lspci -s $busid2 -vvv  |grep -A2 DevCtl: |grep Max )"
        fi
   echo "-------------------------------------"
   echo "${SN}_MaxPayload_before=${be_devmps}"
   echo "${SN}_MaxReadReq_before=${be_devmrrs}"
   echo "${SN}_MaxPayload_after=${af_devmps}"
   echo "${SN}_MaxReadReq_after=${af_devmrrs}"
   echo "-------------------------------------"
done
