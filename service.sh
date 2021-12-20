#!/bin/bash

shopt -s extglob

# We need to resolve the following inconsistency between systemd and xinetd:
# - systemd uses REMOTE_ADDR (like CGI)
# - xinetd uses REMOTE_HOST
# We'll resolve this as follows:
# If running under xinetd, set REMOTE_ADDR to REMOTE_HOST.
# Then proceed to use REMOTE_ADDR in the remainder of the script.
if [[ -z $REMOTE_ADDR && $REMOTE_HOST ]]; then
  # We must be running under xinetd
  REMOTE_ADDR=$REMOTE_HOST
fi

# Note: I noticed xinetd gives a value of '::ffff:127.0.0.1' for localhost
# That's an "IPv4-mapped IPv6" (https://stackoverflow.com/a/49796071)

diagnostic_response() {
  echo "HTTP/1.0 200 OK"
  echo "Connection: close"
  echo "Transfer-Encoding: identity"
  echo "Content-Type: text/plain; charset=utf-8"
  echo "Content-Length: ${#1}"
  echo "Date: $(TZ=UTC; date '+%a, %d %b %Y %T GMT')"
  echo
  echo -n "$1"
  exit
}

do_diagnostic() {
  local remote_addr=$REMOTE_ADDR
  if [[ $REMOTE_ADDR == @(127.*.*.*|::1|::ffff:127.*.*.*) ]]; then
    # The client is on localhost
    # Use our external ip address for testing the geolocation lookup
    remote_addr=$(curl -s -4 https://icanhazip.com/)
  fi
  # request timezone
  local reqTZ="$(curl -sSL "https://ipapi.co/${remote_addr}/timezone")"

  IFS= read -r -d '' content <<EOF
REMOTE_ADDR: $REMOTE_ADDR
remote_addr: $remote_addr
remote_addr: $reqTZ
-------------------------
$(env)
EOF
  diagnostic_response "$content"
}
#do_diagnostic


read -r request
while /bin/true; do
  read -r header
  [ "$header" == $'\r' ] && break
done

# beertime - why we're really here
beertime() {
  beer_o_clock() {
    if [[ "$1" == "" ]]; then
      echo -e "It's the weekend, you must be out of beer.\nGo get some more beer and afterwards reward yourself with two!"
    elif [[ "$(( 10#$2 ))" -ge "$1" ]]; then
      echo -e "Wait... you're not drinking?\nIt's $(date '+%H:%M')!\nGrab a fucking lager, ale or something that isn't water."
    else
      diffTime() {
        printf '%s' $(( $(date -u -d "$later" +%s) - $(date -u -d "$now" +%s) ))
      }

      local now=
      now=$(date -d 'now' '+%F %T %Z')
      local later=
      later=$(date -d "today $1:00:00" '+%F %T %Z')
      local hrsUntil=$(( $(diffTime) / 60 / 60 ))
      now=$(date -d "$now +$hrsUntil hours" '+%F %T %Z')
      local minUntil=$(( $(diffTime) / 60 ))

      echo "T-minus $hrsUntil hour(s) and $minUntil minute(s) until beer o'clock."
    fi
  }

  local hrs=
  hrs=$(date +"%H")
  local day=
  day=$(date +"%w")
  case $day in
    [1-4]*) beer_o_clock 17 "${hrs}";; # mon - thurs
    5) beer_o_clock 16 "${hrs}";; # fri
    *) beer_o_clock;; # sat/sun
  esac
}

# buildRespBody
# param: $1 content-type (String)
buildRespBody() {
  local remote_addr=$REMOTE_ADDR
  if [[ $REMOTE_ADDR == @(127.*.*.*|::1|::ffff:127.*.*.*) ]]; then
    # The client is on localhost
    # Use our external ip address for the geolocation lookup
    remote_addr=$(curl -s -f -4 https://icanhazip.com/)
    if [[ $? != 0 ]]; then
      # No ipv4. Try ipv6:
      remote_addr=$(curl -s -f -s http://icanhazip.com/)
      if [[ $? != 0 ]]; then
        # No ipv6 either. Something is wrong.
        true # We need to call an error handler here
      fi
    fi
  fi
  # Lookup timezone
  local reqTZ="$(curl -sSL "https://ipapi.co/${remote_addr}/timezone")"
  local time=
  time="$(TZ=$reqTZ beertime)"

  if [[ "$1" == 'plain' ]]; then
    printf "%s\r" "${time}"
  elif [[ "$1" == 'json' ]]; then
    local beertime=true
    if [[ "$time" =~ 'T\-minus' ]]; then
      beertime=false
    fi
    echo "{\"success\":true,\"status_code\":200,\"status_text\":\"OK\",\"content\":{\"beertime?\":$beertime,\"message\":\"$(echo "${time}" | tr '\n' ' ')\"}, \"TZ\":\"$reqTZ\"}"
  elif [[ "$1" == 'html' ]]; then
    time=$(echo "$time" | sed ':a;N;$!ba;s/\n/\<\/br\>/g')
    echo "<html><head><link rel='shortcut icon' type='image/x-icon' href='/favicon.ico'></head><body style='font-family: monospace; font-size: 32px;'><p>$time</p></body></html>"
  else
    printf 'Internal Error: No Content-Type passed into buildRespBody.\nPlease file an issue here https://github.com/hhsnopek/beerokclock with the current URL.\nThank you!\r'
  fi
}

# respond
# params:
#   $1 - content-type (String)
#   $2 - body         (String)
respond() {
  echo "HTTP/1.0 200 OK"
  if [[ "$1" == 'application/json' ]]; then
    #echo "Connection: keep-alive"
    echo "Transfer-Encoding: identity"
  #else
    #echo "Connection: close"
  fi
  echo "Content-Type: $1; charset=utf-8"
  echo "Content-Length: ${#2}"
  echo 'Link: </favicon.ico>; rel="icon"'
  #echo "Host: beero.cl"
  echo "Date: $(TZ=UTC; date '+%a, %d %b %Y %T GMT')"
  echo -e "\n$2"
}

# permRedirect
permRedirect() {
  echo 'HTTP/1.0 302 Moved Temporarily'
  #echo "Connection: keep-alive"
  #echo 'Location: http://beero.cl/ock'
  echo 'Location: /ock'
}

# parse url & path
url="${request#GET }"
url="${url% HTTP/*}"
path="${url%%\?*}"
query="${url#*\?}"
if [[ "$path" == "$query" ]]; then
  query=''
fi

# parse it all
altResp=false
if [[ "$path" == '/ock.html' || "$query" == 'type=html' ]]; then # html
  type='html'
  contentType='text/html'
elif [[ "$path" == '/ock.json' || "$query" == 'type=json' ]]; then # json
  type='json'
  contentType='application/json'
elif [[ "$path" == '/ock' && "$query" == '' || "$query" == 'type=plain' ]]; then
  type='plain'
  contentType='text/plain'
elif [[ "$path" == '/favicon' || "$path" == '/favicon.ico' ]]; then # beer emoji
  altResp=true
  echo 'HTTP/1.0 200 OK'
  echo -e "Content-Type: image/x-icon; charset=binary\n"
  #cat '/root/beeroclock/favicon.ico'
  cat '/home/beeroclock/beeroclock/favicon.ico'
  exit 0
elif [[ "${#query}" -gt 9 ]]; then # Unsupported Content-Type
  altResp=true
  echo 'HTTP/1.0 415 Unsupported Media Type'
  echo -e "\n415 Unsupported Media Type"
  exit 0
else # unknown route
  altResp=true
  permRedirect
  exit 0
fi

# if no alternative response, respond
if [[ "$altResp" == false ]]; then
  body="$(buildRespBody $type)"
  respond "$contentType" "$body"
  exit 0
fi
