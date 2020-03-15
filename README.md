## 一键隧道脚本---by ghost ##
    wget --no-check-certificate https://raw.githubusercontent.com/xiaohouzivpn/script/master/ghost.sh chmod +x ghost.sh &&./ghost.sh

## 一键端口转发脚本--by iptables ##
    wget -N --no-check-certificate https://raw.githubusercontent.com/xiaohouzivpn/script/master/iptables-pf.sh && chmod +x iptables-pf.sh && bash iptables-pf.sh
## 一键trojan脚本 ##
    wget --no-check-certificate https://raw.githubusercontent.com/xiaohouzivpn/script/master/trojan.sh && chmod +x trojan.sh && ./trojan.sh
## 一键清除DOCKER日志脚本 ##
    wget https://raw.githubusercontent.com/xiaohouzivpn/script/master/docker_log_delate.sh && chmod +x ./docker_log_delate.sh && ./docker_log_delate.sh
    
## 一键搭建SSR后端——docker ##
  docker run -d --name=xiaohouzi -e NODE_ID=621 -e SPEEDTEST=0 -e API_INTERFACE='glzjinmod' -e MYSQL_HOST=数据库地址 -e MYSQL_PORT=3306 -e MYSQL_USER=数据库用户名 -e MYSQL_PASS=数据库密码 -e MYSQL_DB=数据库名称 --restart=always --network=host --log-opt max-size=10m --log-opt max-file=3 lhie1/ssrmu
