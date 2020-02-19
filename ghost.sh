#!/bin/bash
CONFDIR='/etc/gost'
CONF='/etc/gost/gost.json'
SERVICE_FILE='[Unit]
Description=Gost
After=network.target
Wants=network.target

[Service]
User=root
ExecStart=/usr/bin/gost -C /etc/gost/gost.json
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Type=simple
KillMode=control-group
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target'

PEER_FILE='strategy   random
max_fails    1
fail_timeout    30s
reload    10s'

GOST_JSON='{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": [],
    "ChainNodes": [],
    "Routes": [
        {}
    ]
}'
LIMIT='* soft nofile 51200
* hard nofile 51200'
SYS='fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1'


[[ `id -u` != "0" ]] && echo -e "必须以root用户执行此脚本" && exit

function InstallDependence() {
    echo "安装必要的依赖包"
    YUM_CMD=$(which yum)
    APT_GET_CMD=$(which apt-get)
    CURL=$(which curl)
    WGET=$(which wget)
    GAWK=$(which gawk)
    if [[ ! -z ${YUM_CMD} ]]; then
        PKM=yum
    elif [[ ! -z ${APT_GET_CMD} ]]; then
        PKM=apt-get
    else
        echo -e "不支持的包管理器，脚本终止"
        exit 1;
    fi
    [[ -z ${CURL} ]] && PKG="$PKG curl"
    [[ -z ${WGET} ]] && PKG="$PKG wget"
    [[ -z ${GAWK} ]] && PKG="$PKG gawk"
    $(echo $PKM install -y $PKG)
}

function GetLatestRelease() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"([^"]+)".*/\1/'
}

function InstallGost() {
    local ans
    read -p "使用本地文件？[y/n]：" ans
    if [[ ${ans} = n ]]; then
        echo -e "下载安装最新gost"
        version=`GetLatestRelease ginuerzh/gost | sed -e "s|^v||"`
        wget "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz" -O gost.gz
        gunzip gost.gz
    fi
    mv gost /usr/bin/gost && chmod +x /usr/bin/gost
    echo -e "${SERVICE_FILE}" > /lib/systemd/system/gost.service
    [[ ! -d ${CONF} ]] && mkdir -p ${CONFDIR}
    [[ ! -e ${CONF} ]] && echo -e "${GOST_JSON}" > ${CONF}
    systemctl daemon-reload && systemctl enable gost.service
}

function GetPortInfo() {
    local mode serve_port serve_info chain_info nr_start nr_serve nr_chain nr_end peerfile chain_proto iplist iplist_file serve_proto
    serve_port=$1
    peerfile=${CONFDIR}/${serve_port}/peer
    nr_serve=`awk -v serve_port=${serve_port} -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ && $2 == serve_port {print NR}' ${CONF}`
    nr_chain=$((${nr_serve}+1))
    nr_start=$((${nr_serve}-1))
    if [[ `awk -v nr=${nr_serve} -F ':|"' 'NR==nr {print $5}' ${CONF}` = tcp ]]; then
        if [[ ! -z `awk -v nr=${nr_chain} -F ':|"' 'NR==nr {print $5}' ${CONF}` ]]; then
            mode=0
            chain_info=`awk -v nr=${nr_chain} -F '+|(://)|"|:' 'NR==nr {print "("$6","$7":"$8")"}' ${CONF}`
            serve_info="无"
        else
            mode=1
            local temp=$IFS; IFS=$'\n'
            for i in `cat ${peerfile} | sed -n -e '/^peer/ p'`
            do
                chain_group_proto=`echo ${i} | awk -F '+|(://)' '{print $2}'`
                chain_group_name=`echo ${i} | awk -F "${CONFDIR}/${serve_port}/" '{print $2}'`
                iplist_file=`echo ${i} | awk -F 'ip=' '{print $2}'`
                iplist=`sed ':a ; N;s/\n/,/ ; t a ; ' ${iplist_file}`
                chain_info="${chain_info}(${chain_group_name},${chain_group_proto},${iplist})"
                serve_info="无"
            done
            IFS=${temp}
        fi
    else
        if [[ ! -z `awk -v nr=${nr_serve} -F ':|"' 'NR==nr {print $5}' ${CONF}` ]]; then
            mode=2
            serve_info=`awk -v nr=${nr_serve} -F '(://:)|/|:|"' 'NR==nr {print "("$5","$7":"$8")"}' ${CONF}`
            chain_info="无"
        else
            mode=3
            serve_proto=`awk -F '://|(peer    )' '/^peer/ {print $2}' ${peerfile}`
            iplist_file=`awk -F 'ip=' '/^peer/ {print $2}' ${peerfile}`
            iplist=`sed ':a ; N;s/\n/,/ ; t a ; ' ${iplist_file}`
            serve_info="(${serve_proto},${iplist})"
            chain_info="无"
        fi
    fi
    echo "${serve_port}|${mode}|${serve_info}|${chain_info}|${nr_start}"
}

function DeleteRoutes() {
    [[ -z `awk -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ {print $2}' ${CONF}` ]] && echo -e "尚未添加任何转发线路" && return 0
    local nr ans serve_port
    while true; do
        read -p "输入要删除的本地监听端口, 输入q退出: " serve_port
        [[ ${serve_port} = q ]] && break
        nr=`GetPortInfo ${serve_port} | awk -F '|' '{print $5}'`
        sed -i -e "${nr},$((${nr}+3)) d" ${CONF}
        rm -rf ${CONFDIR}/${serve_port}
        echo -e "端口${serve_port}的相关配置已经删除"
    done
}

function ListRoutes() {
    [[ -z `awk -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ {print $2}' ${CONF}` ]] && echo -e "尚未添加任何转发线路" && return 0
    for i in `awk -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ {print $2}' ${CONF}`; do
        GetPortInfo $i | awk -F '|' 'BEGIN {print "=================================="} \
            { \
                print "监听端口: " $1; \
                if ($2==0) print "工作模式: 客户端无负载均衡"; \
                else if ($2==1)  print "工作模式: 客户端负载均衡"; \
                else if ($2==2)  print "工作模式: 服务端无负载均衡"; \
                else if ($2==3)  print "工作模式: 服务端负载均衡"; \
                    print "服务(协议组，协议，地址): " $3; \
                    print "转发(协议组，协议，地址): " $4 \
                } \
            END {print "=================================="}'
    done
}

function EditRoutes() {
    local serve_port mode ans nr_start nr_serve nr_serve nr_end port_info serve_proto chain_group_proto chain_group_name serve_port_des
    [[ -z `awk -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ {print $2}' ${CONF}` ]] && echo -e "尚未添加任何转发线路" && return 0
    while true; do
        while read -p "输入要修改的线路对应的端口，输入q退出: " serve_port; do
            [[ ${serve_port} = q ]] && return 0
            [[ -z `awk -v serve_port=${serve_port} -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ && $2 == serve_port {print $2}' ${CONF}` ]] && echo -e "该端口不存在" || break
        done
        [[ ${serve_port} = q ]] && return 0
        port_info=`GetPortInfo ${serve_port}`
        mode=`echo ${port_info} | awk -F '|' '{print $2}'`
        nr_start=`echo ${port_info} | awk -F '|' '{print $5}'`
        nr_serve=$((${nr_start}+1))
        nr_chain=$((${nr_start}+2))
        nr_end=$((${nr_start}+3))
        echo -e "选择要做的操作\n1. 修改成其它监听端口\n2. 修改转发"
        read -p "选择：" ans
        if [[ ${ans} = 1 ]]; then
            read -p "修改端口为: " serve_port_des
            case ${mode} in
                0)
                    sed -i -e "${nr_serve} s/${serve_port}/${serve_port_des}/" ${CONF}
                    ;;
                1)
                    sed -i -r -e "${nr_serve} s/${serve_port}/${serve_port_des}/" \
                        -e "${nr_chain} s|(${CONFDIR}/)${serve_port}|\1${serve_port_des}|" ${CONF}
                    sed -i -r -e "s|(${CONFDIR}/)${serve_port}|\1${serve_port_des}|" ${CONFDIR}/${serve_port}/peer
                    mv ${CONFDIR}/${serve_port} ${CONFDIR}/${serve_port_des}
                    ;;
                2)
                    sed -i -r -e "${nr_serve} s|${serve_port}(/)|${serve_port_des}\1|" ${CONF}
                    ;;
                3)
                    sed -i -e "${nr_serve} s/${serve_port}/${serve_port_des}/" ${CONF}
                    sed -i -r -e "s|(${CONFDIR}/)${serve_port}|\1${serve_port_des}|" ${CONFDIR}/${serve_port}/peer
                    mv ${CONFDIR}/${serve_port} ${CONFDIR}/${serve_port_des}
                    ;;
            esac
        else
            case ${mode} in
                0)
                    read -p "转发协议[直接回车默认不修改]: " chain_proto
                    [[ -z ${chain_proto} ]] && chain_proto=`awk -v nr=${nr_chain} -F '+|(://)' 'NR==nr {print $2}' ${CONF}`
                    read -p "转发地址(按照ip:port的格式填写)[回车默认不修改]: " chain_address
                    [[ -z ${chain_address} ]] && chain_address=`awk -v nr=${nr_chain} -F '+|(://)' 'NR==nr {print $3}' ${CONF}`
                    sed -i -e "${nr_chain} c \ \ \ \ \ \ \ \ \ \ \ \ \"ChainNodes\": [ \"forward+${chain_proto}://${chain_address}\" ]" ${CONF}
                    ;;
                1)
                    while true; do
                        echo -e "当前端口负载均衡协议组如下所示："
                        awk -F '+|(://:)|/' '/peer/ {print "协议组名：",$7,"协议：",$2}' ${CONFDIR}/${serve_port}/peer
                        echo -e "选择操作：\n1. 增加协议组\n2. 修改已有协议组\n3. 删除协议组"
                        read -p "选择[序号]，输入q退出: " ans
                        [[ ${ans} = q ]] && break
                        case ${ans} in
                            1)
                                while true; do
                                    while read -p "输入新建的协议组名称，输入q退出: " chain_group_name; do
                                        [[ ${chain_group_name} = q ]] && break
                                        [[ -e ${CONFDIR}/${serve_port}/${chain_group_name} ]] && echo -e "协议组已经存在" || break
                                    done
                                    [[ ${chain_group_name} = q ]] && break
                                    echo -e "0. tcp\t1. tls\t2. mtls\t3. ws\n4. mws\t5. wss\t6. mwss\t7. kcp\n8. quic\t9. ssh\t10. h2\t11. h2c"
                                    read -p "输入协议名称: " chain_group_proto
                                    [[ ! -e ${CONFDIR}/${serve_port}/${chain_group_name} ]] && touch ${CONFDIR}/${serve_port}/${chain_group_name}
                                    echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${CONFDIR}/${serve_port}/${chain_group_name}
                                    sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                                        -e "1 i 例如" \
                                        -e "1 i www.baidu.com:443" \
                                        -e "1 i 192.168.0.1:1234" \
                                        -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${CONFDIR}/${serve_port}/${chain_group_name}
                                    nano ${CONFDIR}/${serve_port}/${chain_group_name}
                                    sed -i -e "1,6 d" ${CONFDIR}/${serve_port}/${chain_group_name}
                                    echo -e "peer    forward+${chain_group_proto}://:?ip=${CONFDIR}/${serve_port}/${chain_group_name}" >> ${CONFDIR}/${serve_port}/peer
                                done
                                ;;
                            2)
                                while true; do
                                    while read -p "输入要修改的协议组名称，输入q退出：" chain_group_name; do
                                        [[ ${chain_group_name} = q ]] && break
                                        [[ -z `ls ${CONFDIR}/${serve_port}/ | grep ${chain_group_name}` ]] && echo -e "该协议组不存在" || break
                                    done
                                    [[ ${chain_group_name} = q ]] && break
                                    echo -e "0. tcp\t1. tls\t2. mtls\t3. ws\n4. mws\t5. wss\t6. mwss\t7. kcp\n8. quic\t9. ssh\t10. h2\t11. h2c"
                                    read -p "协议修改成(协议名称)[直接回车默认不修改]: " chain_group_proto
                                    [[ -z ${chain_group_proto} ]] && chain_group_proto=`awk -v chain_group_name=${chain_group_name} -F '+|(://:)|/' '/^peer/ && $6 == chain_group_name {print $2}' ${CONFDIR}/${serve_port}/peer`
                                    read -p "是否修改协议组内转发地址?[y/n]: " ans
                                    if [[ ${ans} = y ]]; then
                                        sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                                            -e "1 i 例如" \
                                            -e "1 i www.baidu.com:443" \
                                            -e "1 i 192.168.0.1:1234" \
                                            -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" \
                                            -e "1 i 直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" ${CONFDIR}/${serve_port}/${chain_group_name}
                                        nano ${CONFDIR}/${serve_port}/${chain_group_name}
                                        sed -i -e "1,6 d" ${CONFDIR}/${serve_port}/${chain_group_name}
                                    fi
                                    sed -i -e "\|ip=${CONFDIR}/${serve_port}/${chain_group_name}| c peer\ \ \ \ forward+${chain_group_proto}://:?ip=${CONFDIR}/${serve_port}/${chain_group_name}" ${CONFDIR}/${serve_port}/peer
                                done
                                ;;
                            3)
                                while true; do
                                    while read -p "输入要删除的协议组名称，输入q退出: " chain_group_name; do
                                        [[ ${chain_group_name} = q ]] && break
                                        [[ -z `ls ${CONFDIR}/${serve_port}/ | grep ${chain_group_name}` ]] && echo -e "该协议组不存在" || break
                                    done
                                    [[ ${chain_group_name} = q ]] && break
                                    rm -rf ${CONFDIR}/${serve_port}/${chain_group_name}
                                    sed -i -e "\|ip=${CONFDIR}/${serve_port}/${chain_group_name}| d" ${CONFDIR}/${serve_port}/peer
                                done
                                ;;
                        esac
                    done
                    ;;
                2)
                    read -p "转发协议[直接回车默认不修改]: " serve_proto
                    [[ -z ${serve_proto} ]] && serve_proto=`awk -v nr=${nr_serve} -F '(://:)|([[] ")' 'NR==nr {print $2}' ${CONF}`
                    read -p "转发地址(按照 ip或域名:port 的格式填写)[直接回车默认不修改]: " serve_address
                    [[ -z ${serve_address} ]] && serve_address=`awk -v nr=${nr_serve} -F '/|(://:)|(" []])' 'NR==nr {print $3}' ${CONF}`
                    sed -i -e "${nr_serve} c \ \ \ \ \ \ \ \ \ \ \ \ \"ServeNodes\": [ \"${serve_proto}://:${serve_port}/${serve_address}\" ]," ${CONF}
                    ;;
                3)
                    echo -e "0. tcp\t1. tls\t2. mtls\t3. ws\n4. mws\t5. wss\t6. mwss\t7. kcp\n8. quic\t9. ssh\t10. h2\t11. h2c"
                    read -p "转发协议修改为[直接回车默认不修改]: " serve_proto
                    [[ -z ${serve_proto} ]] && serve_proto=`awk -F '://:' '{print $1}' ${CONFDIR}/${serve_port}/peer`
                    read -p "是否修改协议组内转发地址?[y/n]: " ans
                    if [[ ${ans} = y ]]; then
                        sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                            -e "1 i 例如" \
                            -e "1 i www.baidu.com:443" \
                            -e "1 i 192.168.0.1:1234" \
                            -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" \
                            -e "1 i 直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" ${CONFDIR}/${serve_port}/ip
                        nano ${CONFDIR}/${serve_port}/ip
                        sed -i -e "1,6 d" ${CONFDIR}/${serve_port}/ip
                    fi
                    sed -i -e "/^peer/ c peer\ \ \ \ ${serve_proto}://:${serve_port}/:?ip=${CONFDIR}/${serve_port}/ip" ${CONFDIR}/${serve_port}/peer
                    ;;
            esac
        fi
    done
}



function AddRoutes() {
    local ans serve_port serve_ip serve_proto chain_group_name chain_group_proto chain_ip chain_port ssr_address
    echo -e "请选择运行方式\n    1. 客户端(国内机器)\n    2. 服务端(国外机器)\n选择：\c"
    read ans
    if [[ ${ans} = 1 ]]; then
        read -p "请选择本地监听端口: " serve_port
        while [[ ! -z `ss -ntlp | grep ${serve_port}` || ! ${serve_port} =~ ^[0-9]+$ || ! -z `awk -v serve_port=${serve_port} -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ && $2 == serve_port {print $2}' ${CONF}` ]]; do
            read -p "此端口已被使用或者输入非数字，请选择新的端口: " serve_port 
        done
        SERVENODES="\"ServeNodes\": [ \"tcp://:${serve_port}\" ],"
        read -p "是否使用负载均衡？[y/n]: " ans
        if [[ ${ans} = y ]]; then
            mkdir -p ${CONFDIR}/${serve_port}
            echo -e "${PEER_FILE}" > ${CONFDIR}/${serve_port}/peer
            while true; do
                read -p "新建协议组的名字，输入q退出: " chain_group_name
                [[ ${chain_group_name} = q ]] && break
                while [[ -e ${CONFDIR}/${serve_port}/${chain_group_name} ]]; do
                    read -p "协议组已经存在，请输入新的名字: " chain_group_name
                done
                echo -e "请选择该协议组的传输协议(客户端和服务端必须保持一致)"
                echo -e "0. tcp\n1. tls\n2. mtls\n3. ws\n4. mws\n5. wss\n6. mwss\n7. kcp\n8. quic\n9. ssh\n10. h2\n11. h2c"
                read -p "输入所选协议(不要输入序号，输入全称，如wss): " chain_group_proto
                echo -e "peer    forward+${chain_group_proto}://:?ip=${CONFDIR}/${serve_port}/${chain_group_name}" >> ${CONFDIR}/${serve_port}/peer
                [[ ! -e ${CONFDIR}/${serve_port}/${chain_group_name} ]] && touch ${CONFDIR}/${serve_port}/${chain_group_name}
                echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${CONFDIR}/${serve_port}/${chain_group_name}
                sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                    -e "1 i 例如" \
                    -e "1 i www.baidu.com:443" \
                    -e "1 i 192.168.0.1:1234" \
                    -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${CONFDIR}/${serve_port}/${chain_group_name}
                nano ${CONFDIR}/${serve_port}/${chain_group_name}
                sed -i -e "1,6 d" ${CONFDIR}/${serve_port}/${chain_group_name}
            done
            CHAINNODES="\"ChainNodes\": [ \":?peer=${CONFDIR}/${serve_port}/peer\" ]"
        else
            echo -e "请选择传输协议(客户端和服务端必须保持一致)"
            echo -e "0. tcp\n1. tls\n2. mtls\n3. ws\n4. mws\n5. wss\n6. mwss\n7. kcp\n8. quic\n9. ssh\n10. h2\n11. h2c"
            read -p "输入所选协议(不要输入序号，输入全称，如wss): " serve_proto
            read -p "输入服务端ip地址或域名: " chain_ip
            read -p "输入服务端gost运行端口: " chain_port
            CHAINNODES="\"ChainNodes\": [ \"forward+${serve_proto}://${chain_ip}:${chain_port}\" ]"
        fi
    elif [[ ${ans} = 2 ]]; then
        read -p "请选择本地监听端口: " serve_port
        while [[ ! -z `ss -ntlp | grep ${serve_port}` || ! ${serve_port} =~ ^[0-9]+$ || ! -z `awk -v serve_port=${serve_port} -F '(://:)|(gost/)|(/peer)|(" ])|/([^[:alpha:]])' '/"ServeNodes": \[ ".+" \]/ && $2 == serve_port {print $2}' ${CONF}` ]]; do
            read -p "此端口已被使用或者输入非数字，请选择新的端口: " serve_port
        done
        echo -e "请选择传输协议(客户端和服务端必须保持一致)"
        echo -e "0. tcp\n1. tls\n2. mtls\n3. ws\n4. mws\n5. wss\n6. mwss\n7. kcp\n8. quic\n9. ssh\n10. h2\n11. h2c"
        read -p "输入所选协议(不要输入序号，输入全称，如wss): " serve_proto
        read -p "是否使用负载均衡？[y/n]: " ans
        if [[ ${ans} = y ]]; then
            mkdir -p ${CONFDIR}/${serve_port}
            echo -e "${PEER_FILE}" > ${CONFDIR}/${serve_port}/peer
            echo -e "peer    ${serve_proto}://:${serve_port}/:?ip=${CONFDIR}/${serve_port}/ip" >> ${CONFDIR}/${serve_port}/peer
            [[ ! -e ${CONFDIR}/${serve_port}/ip ]] && touch ${CONFDIR}/${load_group}/ip
            echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${CONFDIR}/${serve_port}/ip
            sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                -e "1 i 例如" \
                -e "1 i www.baidu.com:443" \
                -e "1 i 192.168.0.1:1234" \
                -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${CONFDIR}/${serve_port}/ip
            nano ${CONFDIR}/${serve_port}/ip
            sed -i -e "1,6 d" ${CONFDIR}/${serve_port}/ip
            SERVENODES="\"ServeNodes\": [ \":?peer=${CONFDIR}/${serve_port}/peer\" ],"
        else
            read -p "SSR服务地址(按照 ip或域名:端口 的格式填写)：" ssr_address
            SERVENODES="\"ServeNodes\": [ \"${serve_proto}://:${serve_port}/${ssr_address}\" ],"
        fi
        CHAINNODES="\"ChainNodes\": []"
    else
        echo -e "错误的模式"
        return 1
    fi
    sed -i -e "/`echo -e ${SERVENODES}`/,+1 d" ${CONF}
    sed -i -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ {" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ \ \ \ \ ${SERVENODES}" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ \ \ \ \ ${CHAINNODES}" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ }," ${CONF}
}

while true; do
    echo -e "\n"
    echo -e "选择任务："
    echo -e "1. 安装gost"
    echo -e "2. 添加隧道转发"
    echo -e "3. 查看已有转发"
    echo -e "4. 修改已有转发"
    echo -e "5. 删除已有转发"
    echo -e "6. 查看当前运行日志"
    echo -e "7. 启动gost"
    echo -e "8. 停止gost"
    echo -e "9. 优化网络连接参数(执行一次就行)"
    read -p "选择一个任务[序号，按 q 或者 Ctrl+c 退出脚本]: " ans
    case ${ans} in
        1)
            echo -e "\n"
            InstallDependence
            InstallGost
            ;;
        2)
            echo -e "\n"
            AddRoutes
            ;;
        3)
            echo -e "\n"
            ListRoutes
            ;;
        4)
            echo -e "\n"
            EditRoutes
            ;;
        5)
            echo -e "\n"
            DeleteRoutes
            ;;
        6)
            journalctl -u gost -f
            ;;
        7)
            echo -e "\n"
            [[ ! -z `ss -ntlp | grep gost` ]] && echo -e "gost已经在运行中" && continue
            systemctl start gost.service
            sleep 2s
            if [[ ! -z `ss -ntlp | grep gost` ]]; then
                echo -e "成功启动gost" && continue
            else
                echo -e "启动失败"
            fi
            ;;
        8)
            echo -e "\n"
            [[ -z `ss -ntlp | grep gost` ]] && echo -e "gost并未启动" && continue
            systemctl stop gost.service
            sleep 2s
            if [[ -z `ss -ntlp | grep gost` ]]; then
                echo -e "成功停止gost" && continue
            else
                echo -e "停止失败"
            fi
            ;;
        9)
            echo -e "\n"
            echo -e "${LIMIT}" >> /etc/security/limits.conf
            ulimit -n 51200
            echo -e "${SYS}" >> /etc/sysctl.conf
            sysctl -p
            echo -e "优化完成"
            ;;
        q)
            break
            ;;
    esac
done

exit 0
