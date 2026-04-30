:local updaterUrl "https://120.79.157.95:8444/update-vpn-ip"
:local sharedSecret "381d6073d7435ce1caa2cd341da06c4a453031c0c7993b8b7bfb8f35d137cb32"
:local ipsecPeer "alibaba-peer"
:local storeScript "oogi-last-public-ip"
:local currentIp ""
:do { :set currentIp [:tostr [:resolve myip.opendns.com server=208.67.222.222]] } on-error={ :log error "oogi-vpn: resolve failed" ; :return }
:if ($currentIp = "") do={ :log error "oogi-vpn: empty IP" ; :return }
:local lastIp ""
:if ([:len [/system script find name=$storeScript]] > 0) do={
:set lastIp [:tostr [/system script get [/system script find name=$storeScript] source]]
}
:if ($currentIp = $lastIp) do={ :log info ("oogi-vpn: unchanged " . $currentIp) ; :return }
:log warning ("oogi-vpn: changed " . $lastIp . " to " . $currentIp)
:local body ("{" . "\22" . "newIp" . "\22" . ":" . "\22" . $currentIp . "\22" . "}")
:local authHeader ("Authorization: Bearer " . $sharedSecret)
:local fetchResult
:do { :set fetchResult [/tool fetch url=$updaterUrl http-method=post http-header-field=$authHeader http-data=$body check-certificate=no output=user as-value] } on-error={ :log error "oogi-vpn: fetch failed" ; :return }
:local respBody ($fetchResult->"data")
:if ([:typeof $respBody] = "nothing") do={ :log error "oogi-vpn: empty response" ; :return }
:local needle ("\22" . "status" . "\22" . ":" . "\22" . "ok" . "\22")
:local found [:find $respBody $needle]
:if (!([:typeof $found] = "num")) do={ :log error ("oogi-vpn: error " . $respBody) ; :return }
:log info ("oogi-vpn: Alibaba OK " . $respBody)
/ip ipsec identity set [/ip ipsec identity find peer=$ipsecPeer] my-id=("address:" . $currentIp)
/ip ipsec installed-sa flush
:if ([:len [/system script find name=$storeScript]] = 0) do={ /system script add name=$storeScript source=$currentIp } else={ /system script set [/system script find name=$storeScript] source=$currentIp }
:log info ("oogi-vpn: done " . $currentIp)
