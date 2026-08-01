# E-Shoes


# 一键脚本

实时获取！

FILE="eshoes.sh" && apt update -y && apt install -y curl && curl -sSL -H "Accept: application/vnd.github.v3.raw" -o $FILE "https://api.github.com/repos/xtonly/E-Shoes/contents/eshoes.sh?ref=main" && chmod +x $FILE && ./$FILE


如果有相关客户端提示 未固定证书！

请在服务器端通过以下命令获取证书填入软件！

cat /etc/shoes/cert.pem




# 基于Shoes项目：https://github.com/cfal/shoes
