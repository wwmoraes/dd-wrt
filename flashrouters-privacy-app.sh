#!/bin/sh

set +x

# link LetsEncrypt certificates and enable SSL (experimental)
function enable_ssl(){
    [ -f ${WORKDIR}/certs/fullchain.pem ]\
      && (grep -q -e "/etc/cert.pem" /proc/mounts\
      || mount -o bind ${WORKDIR}/certs/fullchain.pem /etc/cert.pem)\
      && [ -f ${WORKDIR}/certs/privkey.pem ]\
      && (grep -q -e "/etc/key.pem" /proc/mounts\
      || mount -o bind ${WORKDIR}/certs/privkey.pem /etc/key.pem)\
      && nvram set https_enable=1\
      && local lan_ip=$(nvram get lan_ipaddr)\
      && sed "/${lan_ip}\\t${HTTPS_HOST}/d" /etc/hosts > ${WORKDIR}/hosts.tmp\
      && cat ${WORKDIR}/hosts.tmp > /etc/hosts\
      && rm -rf ${WORKDIR}/hosts.tmp\
      && printf "${lan_ip}\t${HTTPS_HOST}\n" >> /etc/hosts
}


SSL=0
APP=${APP:-'flashr-mypage'} # application name
TAG=${TAG:-'live'} # git tag/branch
COMMIT=${COMMIT:-'198f41dee361dffa66b448b75f45226a8f4aede0'} # git commit
DEV=${DEV:-'0'} # detect dev. api
BOOTSTRAP_CSS='user/css/bootstrap.min.css' # bootstrap theme
LOGO='user/img/logo.png' # button logo
USER_FS=${USER_FS:-$(eval echo "~root")}
WWWROOT=${WWWROOT:-"${USER_FS}/${APP}"} # symbolic link name
HTTPS_HOST=${HTTPS_HOST:-'router.belodedenko.me'} # name on the SSL cert
API_HOST=${API_HOST:-'https://api.flashroutersapp.com'} # VPN providers API (dev/public)
API_VERSION=${API_VERSION:-'1.0'} # VPN providers API version
DEFAULT_PROVIDER_GROUP=${DEFAULT_PROVIDER_GROUP:-'privacy'} # VPN provider group name
DEFAULT_PROVIDER=${DEFAULT_PROVIDER:-'NordVPN'} # VPN provider name
DEFAULT_AUTO_CONNECT=${DEFAULT_AUTO_CONNECT:-'true'} # auto connect enabled by default
DEFAULT_KILL_SWITCH=${DEFAULT_KILL_SWITCH:-'false'} # global kill-switch disabled by default
DEFAULT_REDIRECT='https://bit.ly/2MWJaSy'
CONN_TIMEOUT=${CONN_TIMEOUT:-'5'} # seconds
OVPN_VERSION="$(openvpn --version | head -n 1 | awk '{split($2,result,"."); print result[1]"."result[2]}')"
MIN_OS_VERSION=${MIN_OS_VERSION:-'34929'}
MAX_OS_VERSION=${MAX_OS_VERSION:-'99999'}
WORKDIR=${WWWROOT}
CACHE_BUST=${CACHE_BUST:-'0'}
CURL_OPTS="--fail --silent --retry 3 --connect-timeout ${CONN_TIMEOUT} -L"


# checks
touch "${USER_FS}/__rwtest" || (printf "\$?=$? ${USER_FS} not writable\n"; exit 1)
[ -f "${USER_FS}/__rwtest" ] && rm ${USER_FS}/__rwtest
which curl >/dev/null 2>/dev/null || (printf "\$?=$? cURL required\n" && exit 1)
which openssl >/dev/null 2>/dev/null || (printf "\$?=$? OpenSSL required\n" && exit 1)
expr "${OVPN_VERSION}" : "2\.[3-9]" >/dev/null 2>/dev/null || (openvpn --version && exit 1)

# optionally enable SSL
[[ "${SSL}" == '1' ]] && (printf 'enabling SSL (reboot required)...\n' && enable_ssl)

printf 'detecting device... '
DEVICE='DD-WRT'
if [[ "${DEVICE}" ==  'DD-WRT' ]]; then
    printf "selected=${DEVICE} custom=$(nvram get router_name)\n"
    DD_BOARD='Unknown Unknown'
    DD_BOARD="$(nvram get DD_BOARD)"
    DD_MODEL="$(echo ${DD_BOARD} | awk '{print $2}')"
    DD_BRAND="$(echo ${DD_BOARD} | awk '{print $1}')"
    case ${DD_BOARD} in
        'Netgear R6300V2') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R6400 v1') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R6400 v2') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R7000') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R7000P') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R7800') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear R8000') printf "compatible router: ${DD_BOARD}\n";;
        'Netgear XR500') printf "compatible router: ${DD_BOARD}\n";;
        # R9000
        'Netgear Nighthawk X10') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC5300') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC56U') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC66U') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC68U B1') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC1900P') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC68U C1') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC87U') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-N16') printf "compatible router: ${DD_BOARD}\n";;
        'Linksys WRT1200AC') printf "compatible router: ${DD_BOARD}\n";;
        'Linksys WRT1900ACS') printf "compatible router: ${DD_BOARD}\n";;
        'Linksys WRT1900ACv2') printf "compatible router: ${DD_BOARD}\n";;
        'Linksys WRT3200ACM') printf "compatible router: ${DD_BOARD}\n";;
        'Linksys WRT32X') printf "compatible router: ${DD_BOARD}\n";;
        'Asus RT-AC3100') printf "compatible router: ${DD_BOARD}\n";;
        *) printf "router ${DD_BOARD} is not officially supported\n";;
    esac
    OS_VERSION="$(nvram get os_version | grep -o '\d*')"
    if [[ ${OS_VERSION} -lt ${MIN_OS_VERSION} ]] || [[ ${OS_VERSION} -gt ${MAX_OS_VERSION} ]]; then
        printf "incompatible OS: ${OS_VERSION} min=${MIN_OS_VERSION} max=${MAX_OS_VERSION}\n"
        exit 1
    else
        printf "compatible OS: ${OS_VERSION}\n"
    fi
    # prior versions didn't have CA certificates in the firmware
    [ ${OS_VERSION} -lt 40189 ] && CURL_OPTS="${CURL_OPTS} --insecure"
else
    printf "incompatible device: ${DEVICE}\n"
    exit 1
fi

# update CA certs
lines=0
if [ -e /tmp/cacert.pem ]; then
    lines=$(openssl crl2pkcs7 -nocrl -certfile /tmp/cacert.pem | openssl pkcs7 -print_certs | wc -l)
fi
if [ ! ${lines} -gt 0 ]; then
    printf 'downloading CA cert(s)...\n'
    curl ${CURL_OPTS} http://curl.haxx.se/ca/cacert.pem > /tmp/cacert.pem\
      || (printf "\$?=$? CA cert(s) required\n" && echo exit 1)
else
    printf "CA cert file with ${lines} lines present\n"
fi
export CURL_CA_BUNDLE=/tmp/cacert.pem

# disconnect VPN if already installed
if ps | grep '[o]penvpn' > /dev/null; then
    printf "disconnecting VPN...\n"
    COMMAND=Disconnect "${WWWROOT}/mypage.sh" >/dev/null 2>/dev/null && printf "disconnected OK\n"
fi

# read NVRAM
USERNAME=${USERNAME:-$(nvram get flashr_vpn_username | sed "s#\##\\\\\##g")}
PASSWORD=${PASSWORD:-$(nvram get flashr_vpn_passwd | sed "s#\##\\\\\##g")}
AUTO_CONNECT=${AUTO_CONNECT:-$(nvram get flashr_auto_connect)}
KILL_SWITCH=${KILL_SWITCH:-$(nvram get flashr_kill_switch)}
PROVIDER_GROUP=${PROVIDER_GROUP:-$(nvram get flashr_vpn_provider_group)}
PROVIDER=${PROVIDER:-$(nvram get flashr_vpn_provider)}
LOCATION_GROUP=${LOCATION_GROUP:-$(nvram get flashr_vpn_location_group)}
LOCATION=${LOCATION:-$(nvram get flashr_vpn_location)}

if [ "${PROVIDER_GROUP}" != "${DEFAULT_PROVIDER_GROUP}" ] \
  || [ "${PROVIDER}" != "${DEFAULT_PROVIDER}" ]; then
    if [ "${DEVICE}" == 'DD-WRT' ]; then
        nvram unset ping_ip
        for nvev in $(nvram show | grep '^[f]lashr_[^bb|^jwt|^guid|^secret|^kill_switch]' \
          | awk -F'=' '{print $1}'); do
            nvram unset "${nvev}" && printf "unset ${nvev} OK\n"
        done
        if ps | grep '[o]penvpn' > /dev/null; then
            printf "disconnecting VPN...\n"
            killall -q -QUIT openvpn > /dev/null
            [ -e "${WORKDIR}/client.ovpn" ] && rm ${WORKDIR}/client.ovpn > /dev/null
            [ -e "${WORKDIR}/credentials.txt" ] && rm ${WORKDIR}/credentials.txt > /dev/null
            [ -e "${WORKDIR}/crl.pem" ] && rm ${WORKDIR}/crl.pem > /dev/null
        fi
        AUTO_CONNECT='false'
    fi
fi

if [ "${DEV}" == '1' ]; then
    printf 'detecting local dev. API... '
    API_HOST_LOCAL="$(netstat -n 2>/dev/null | awk '/:22 / && /ESTABLISHED/ {split($5,result,":"); print result[1]}')" \
     && curl -I "http://${API_HOST_LOCAL}:5000/api/v${API_VERSION}/ping" --connect-timeout 1 --max-time 1 --fail >/dev/null 2>/dev/null \
     && API_HOST="http://${API_HOST_LOCAL}:5000" \
     || for ip in $(cat /proc/net/arp | grep br0 | awk '{print $1}'); do
            API_HOST_LOCAL=${ip} \
             && curl -I "http://${API_HOST_LOCAL}:5000/api/v${API_VERSION}/ping" --connect-timeout 1 --max-time 1 --fail >/dev/null 2>/dev/null \
             && API_HOST="http://${API_HOST_LOCAL}:5000"
            if [ $? == 0 ]; then CURL_OPTS="${CURL_OPTS} --insecure"; break; fi
        done
fi

API_URL="${API_HOST}/api/v${API_VERSION}"
printf "selected API on ${API_URL}\n"

[ "${DEFAULT_PROVIDER_GROUP}" ] && printf "selected ${DEFAULT_PROVIDER_GROUP} VPN provider group\n"
[ "${DEFAULT_PROVIDER}" ] && printf "selected ${DEFAULT_PROVIDER} VPN provider(s)\n"

if [ "${DEVICE}" == 'DD-WRT' ]; then
    [ -e "${WWWROOT}" ]\
      && printf 'removing FlashRouters MyPage Extension...\n'\
      && rm -rf ${WWWROOT}

    printf 'installing FlashRouters MyPage Extension...\n'\
      && cd ${USER_FS}\
      && nvram set mypage_redirect_html="$(printf "#!/bin/sh\nprintf '<html><head><meta http-equiv=\"refresh\" content=\"1;url=${DEFAULT_REDIRECT}\"><link rel=\"canonical\" href=\"${DEFAULT_REDIRECT}\"/><script>window.location.href=\"${DEFAULT_REDIRECT}\"</script><title>redirect</title></head><body>Click <a href=\"${DEFAULT_REDIRECT}\">here</a></body></html>\n'" | uuencode -)"\
      && curl -L ${API_URL}/ddwrt/download --connect-timeout ${CONN_TIMEOUT} --fail --silent | gunzip - | tar -xf - -C ${USER_FS} >/dev/null 2>/dev/null\
      && sed -i "s#{{__TAG__}}#${TAG}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__COMMIT__}}#${COMMIT}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEV__}}#${DEV}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__API_URL__}}#${API_URL}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__API_HOST__}}#${API_HOST}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__WORKDIR__}}#${WWWROOT}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEVICE__}}#${DEVICE}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DD_BOARD__}}#${DD_BOARD}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DD_MODEL__}}#${DD_MODEL}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DD_BRAND__}}#${DD_BRAND}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__OS_VERSION__}}#${OS_VERSION}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEFAULT_AUTO_CONNECT__}}#${DEFAULT_AUTO_CONNECT}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEFAULT_KILL_SWITCH__}}#${DEFAULT_KILL_SWITCH}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEFAULT_PROVIDER__}}#${DEFAULT_PROVIDER}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__DEFAULT_PROVIDER_GROUP__}}#${DEFAULT_PROVIDER_GROUP}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__BOOTSTRAP_CSS__}}#${BOOTSTRAP_CSS}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__LOGO__}}#${LOGO}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__CONN_TIMEOUT__}}#${CONN_TIMEOUT}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__OVPN_VERSION__}}#${OVPN_VERSION}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__OVPN_VERSION__}}#${OVPN_VERSION}#g" ${USER_FS}/${APP}/mypage.sh\
      && sed -i "s#{{__CACHE_BUST__}}#${CACHE_BUST}#g" ${USER_FS}/${APP}/mypage.sh\
      && for script in log.sh status.sh profile.sh download.sh; do sed -i "s#{{__WORKDIR__}}#${WWWROOT}#g" ${USER_FS}/${APP}/${script}; done\
      && for script in log.sh status.sh profile.sh download.sh; do sed -i "s#{{__CACHE_BUST__}}#${CACHE_BUST}#g" ${USER_FS}/${APP}/${script}; done\
      && rm -rf /tmp/www\
      && ln -s ${WWWROOT} /tmp/www\
      && [ -e ${WWWROOT}/mypage.sh ]\
      || (mkdir -p ${WWWROOT} && nvram get mypage_redirect_html | uudecode > ${WWWROOT}/mypage.sh && chmod +x ${WWWROOT}/mypage.sh) || true\
      && rm -rf ${WWWROOT}/user\
      && ln -s ${WWWROOT} ${WWWROOT}/user\
      && chown -hR root:root ${WWWROOT}\
      && nvram set mypage_scripts="${WWWROOT}/mypage.sh ${WWWROOT}/log.sh ${WWWROOT}/status.sh ${WWWROOT}/profile.sh ${WWWROOT}/download.sh"\
      && nvram commit\
      && printf 'Please navigate to Status > MyPage.\n'\
      && printf 'Installation Success!\n'
elif [ "${DEVICE}" == 'Tomato' ]; then
    printf "${DEVICE} not implemented.\n"
    exit 1
else
    printf "${DEVICE} not supported.\n"
    exit 1
fi

if [[ "${AUTO_CONNECT}" == 'true' ]]; then
    if [[ "${USERNAME}" != '' ]]\
      && [[ "${PASSWORD}" != '' ]]\
      && [[ "${PROVIDER_GROUP}" != '' ]]\
      && [[ "${PROVIDER}" != '' ]]\
      && [[ "${LOCATION_GROUP}" != '' ]]\
      && [[ "${LOCATION}" != '' ]]; then
          printf 'connecting VPN...'\
            && COMMAND=Connect "${WWWROOT}/mypage.sh" >/dev/null 2>/dev/null\
            && printf "connected OK\n"
    fi
fi
