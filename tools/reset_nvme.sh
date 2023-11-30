#!/bin/bash 

bdf_list=$(cd /sys/bus/pci/drivers/nvme/; ls | grep -E [0-9]{4}:[0-9]{2}:[0-9]{2}.[0-9]{1} | sort -V)
for bdf in ${bdf_list};
do
    echo "unbind $bdf"
    echo $bdf > /sys/bus/pci/drivers/nvme/unbind
done

for bdf in ${bdf_list};
do
    echo "bind $bdf"
    echo $bdf > /sys/bus/pci/drivers/nvme/bind
done