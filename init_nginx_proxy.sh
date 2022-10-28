#!/bin/bash

init_mnt_gcs() {
    echo 'check if need to init /mnt/gcs'

    mount_result=$(df -h | grep /mnt/gcs)
    if [[ -z $mount_result ]]; then
        echo 'not mounted, begin to init /mnt/gcs'
        mkdir /mnt/gcs/
        BUCKET=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/cdn-config-bucket' -H 'Metadata-Flavor: Google')
        gcsfuse -o allow_other $BUCKET /mnt/gcs
        echo $BUCKET '/mnt/gcs gcsfuse rw,allow_other,file_mode=777,dir_mode=777' >>/etc/fstab
        echo '/mnt/gcs has been mounted'
    else
        echo 'find mounted /mnt/gcs, will not mount again'
    fi
}

init_local_ssd() {

    if [ -b "/dev/md0" ]; then
        echo "/dev/md0 exists. local ssd has been init"
        mkdir /localssd
        mount -o discard,defaults,nobarrier /dev/md0 /localssd
        return
    else
        echo '/dev/md0 not exist, begin to init local ssd'
    fi

    localssd_num=$(ls -al /dev | grep nvme0n | wc -l)
    echo localssd num: $localssd_num

    str_nvme0n=''
    for i in $(seq 1 $localssd_num); do
        str_nvme0n="$str_nvme0n /dev/nvme0n$i"
    done

    mdadm --create /dev/md0 --level=0 --raid-devices=$localssd_num $str_nvme0n

    mkfs.ext4 -F /dev/md0

    mv /etc/mdadm/mdadm.conf /etc/mdadm/mdadm.conf.bak
    sed -e '/\/dev\/md0/d' /etc/mdadm/mdadm.conf.bak >/etc/mdadm/mdadm.conf
    mdadm --detail --scan | tee -a /etc/mdadm/mdadm.conf

    update-initramfs -u

    if [ -d '/localssd' ]; then
        echo 'remove old /localssd and create new one'
        rm -rf /localssd
    fi

    mkdir /localssd
    mount -o discard,defaults,nobarrier /dev/md0 /localssd

    mount_result=$(df -h | grep /localssd)
    if [[ -z $mount_result ]]; then
        echo 'fail to mount /dev/md0 to /localssd'
        return
    fi

    mkdir -p /localssd/cache/tmp
    echo 'healthcheck' >/localssd/index.html

    mv /etc/fstab /etc/fstab.bak
    sed -e '/\/localssd/d' /etc/fstab.bak >/etc/fstab
    echo UUID=$(sudo blkid -s UUID -o value /dev/md0) /localssd ext4 discard,defaults,nobarrier,nofail 0 2 | tee -a /etc/fstab
}

init_upstream_conf() {
    UPSTREAM_FILE_NAME='/etc/nginx/upstream.conf'

    echo "init upstream conf"

    mig_name=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/created-by' -H 'Metadata-Flavor: Google')
    echo "MIG name: $mig_name"

    gcloud compute instance-groups managed list-instances $mig_name \
        --uri | xargs -I '{}' gcloud compute instances describe '{}' \
        --flatten networkInterfaces \
        --format 'csv[no-heading](networkInterfaces.networkIP)' >./ipaddr.list

    new_ipaddr=$(sort -n -t . -k 1,1 -k 2,2 -k 3,3 -k 4,4 ./ipaddr.list)
    rm -rf ./ipaddr.list
    echo $new_ipaddr >/etc/nginx/nginx_proxy_list

    echo 'upstream cache {' >$UPSTREAM_FILE_NAME
    echo $'\thash $uri consistent;' >>$UPSTREAM_FILE_NAME
    echo $'\tkeepalive 256;' >>$UPSTREAM_FILE_NAME
    echo $'\tkeepalive_timeout 600s;' >>$UPSTREAM_FILE_NAME
    echo $'\tkeepalive_requests 3600;' >>$UPSTREAM_FILE_NAME

    for ip in $new_ipaddr; do
        echo "found ip address in MIG: $ip"
        echo $'\tserver'" $ip:8080;" >>$UPSTREAM_FILE_NAME
    done

    echo $'\tcheck port=8081 interval=5000 rise=2 fall=5 timeout=5000 type=http;' >>$UPSTREAM_FILE_NAME
    echo $'\tcheck_http_send "HEAD / HTTP/1.0\\r\\n\\r\\n";' >>$UPSTREAM_FILE_NAME
    echo $'\tcheck_http_expect_alive http_2xx http_3xx;' >>$UPSTREAM_FILE_NAME
    echo '}' >>$UPSTREAM_FILE_NAME
}

init_origin_conf() {
    echo "init orgin conf"
    ORIGIN_FILE_NAME='/etc/nginx/origin.conf'
    UPSTREAM_ENDPOINT=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/upstream_endpoint' -H 'Metadata-Flavor: Google')
    UPSTREAM_HOSTNAME=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/upstream_hostname' -H 'Metadata-Flavor: Google')
    echo "upstream endpoint: $UPSTREAM_ENDPOINT"
    echo "upstream hostname: $UPSTREAM_HOSTNAME"
    echo 'set $upstream_endpoint '"$UPSTREAM_ENDPOINT;" >$ORIGIN_FILE_NAME
    echo 'set $upstream_hostname '"$UPSTREAM_HOSTNAME;" >>$ORIGIN_FILE_NAME
}

update_cron() {
    #cronjob has not the environment variable
    ln -sf /snap/bin/gcloud /usr/bin/gcloud
    mv /etc/crontab /etc/crontab.bak
    sed -e '/update_nginx_proxy.sh/d' /etc/crontab.bak >/etc/crontab
    echo "* * * * * root bash /mnt/gcs/update_nginx_proxy.sh" >>/etc/crontab
    service cron restart
}

init_mnt_gcs
mount_result=$(df -h | grep /mnt/gcs)
if [[ -z $mount_result ]]; then
    echo "Fail to init /mnt/gcs, check if the GCS bucket $BUCKET exists or access right"
    exit -1
fi

#init_origin_conf

nginx_type=$(curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/nginx-proxy-type' -H 'Metadata-Flavor: Google')
nginx_conf_localssd=nginx_localssd.conf
nginx_conf_bypass=nginx_bypass.conf
source /mnt/gcs/global_conf

if [ $nginx_type = 'localssd' ]; then
    echo 'nginx proxy type: localssd'
    ln -sf /mnt/gcs/$nginx_conf_localssd /etc/nginx/nginx.conf
    echo $nginx_conf_localssd > /etc/nginx/current_nginx_conf
    init_local_ssd
    init_upstream_conf
    service nginx start
    echo "waiting for the MIG stable to update upstream conf again"
    gcloud compute instance-groups managed wait-until $mig_name --stable
    init_upstream_conf
    service nginx reload
    update_cron
else
    echo 'nginx proxy type: bypass'
    ln -sf /mnt/gcs/$nginx_conf_bypass /etc/nginx/nginx.conf
    echo $nginx_conf_bypass > /etc/nginx/current_nginx_conf
    service nginx restart
fi
