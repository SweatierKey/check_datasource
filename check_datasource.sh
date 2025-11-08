#!/usr/bin/env bash

set -euo pipefail

trap 'echo "Script terminato con codice $?"' EXIT


error_handler() {
    local exit_code=$?
    local line_no=$1
    echo "Errore nello script alla riga $line_no, exit code: $exit_code"
}
trap 'error_handler $LINENO' ERR


if ! script_realpath="$(realpath "$0" 2>/dev/null)"; then
	script_realpath="$(readlink -f "$0")"
fi
script_dirname="$(dirname "$script_realpath")"
python_script="${script_dirname}/python_script.py"


cleanup() {
	echo -e "\n Program Interrupted"
	echo "OLDPWD: $PWD"
	cd "$script_dirname"
	echo "NEWPWD: $PWD"
}
trap cleanup INT

xml_grab() {
    local config_xml="$1"
    local admin_name

    # Prendi il nome dell'admin server
    admin_name=$(xmllint --xpath "string(//*[local-name()='admin-server-name'])" "$config_xml")

    # Estraggo tutti i valori in una volta sola
    while IFS='|' read -r listen_address listen_port_enabled clear_port ssl_enabled ssl_port trust_keystore cluster_multicast_port; do
        # Le variabili vengono assegnate direttamente nella funzione
        export listen_address listen_port_enabled clear_port ssl_enabled ssl_port trust_keystore cluster_multicast_port
    done < <(
        xmllint --xpath "
            concat(
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-address']
                | //*[local-name()='admin-server']/*[local-name()='listen-address']), '|',
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-port-enabled']
                | //*[local-name()='admin-server']/*[local-name()='listen-port-enabled']), '|',
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-port']
                | //*[local-name()='admin-server']/*[local-name()='listen-port']), '|',
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='ssl']/*[local-name()='enabled']), '|',
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='ssl']/*[local-name()='listen-port']), '|',
                string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='custom-trust-key-store-file-name']), '|',
                string(//*[local-name()='cluster']/*[local-name()='multicast-port'])
            )
        " "$config_xml"
    )
}

# xml_grab() {
# 	local config_xml="$1"
# 	local admin_name 
# 
# 	admin_name=$(xmllint --xpath "string(//*[local-name()='admin-server-name'])" "$config_xml")
# 	listen_address=$(xmllint --xpath "
# 	  string(
# 	    //*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-address'] |
# 	    //*[local-name()='admin-server']/*[local-name()='listen-address']
# 	  )
# 	" "$config_xml")
# 	listen_port_enabled=$(xmllint --xpath "
# 	  string(
# 	    //*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-port-enabled'] |
# 	    //*[local-name()='admin-server']/*[local-name()='listen-port-enabled']
# 	  )
# 	  " "$config_xml")
# 	clear_port=$(xmllint --xpath "
# 	  string(
# 	    //*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='listen-port'] |
# 	    //*[local-name()='admin-server']/*[local-name()='listen-port']
# 	  )
# 	" "$config_xml")
# 	cluster_multicast_port=$(xmllint --xpath "string(//*[local-name()='cluster']/*[local-name()='multicast-port'])" "$config_xml")
# 	ssl_enabled=$(xmllint --xpath "
# 	  string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='ssl']/*[local-name()='enabled'])
# 	" "$config_xml")
# 	ssl_port=$(xmllint --xpath "
# 	  string(
# 	    //*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='ssl']/*[local-name()='listen-port']
# 	  )
# 	" "$config_xml")
# 	trust_keystore=$(
# 	  xmllint --xpath "string(//*[local-name()='server'][*[local-name()='name']='${admin_name}']/*[local-name()='custom-trust-key-store-file-name'])" "$config_xml")
# }

exec_wlst() {
	local java_options=(
		-Dweblogic.security.TrustKeyStore=CustomTrust \
	    -Dweblogic.security.CustomTrustKeyStoreFileName="$trust_keystore" \
	    -Dweblogic.security.CustomTrustKeyStorePassPhrase=password)
	
	local wlst="${WL_HOME}/../oracle_common/common/bin/wlst.sh"
	local args=(
		"$python_script" \
		"$username" \
		"$password" \
		"$protocol" \
		"$listen_address" \
		"$listen_port")

	if [[ -f "$wlst" ]]; then
		if [[ -n "$trust_keystore" ]]; then
			export JAVA_OPTIONS="${java_options[*]}"
			"$wlst" "${args[*]}"
		else
			"$wlst" "${args[*]}"
		fi
	else
		if [[ -n "$trust_keystore" ]]; then
			java "${java_options[*]}" weblogic.WLST "${args[*]}"
		else
			java weblogic.WLST "${args[*]}"
		fi
	fi
}

report_data() {

	if [[ -n "$cluster_multicast_port" ]]; then
	    listen_port="$cluster_multicast_port"
	    protocol="t3"
	    echo "Usata la multicast-port del cluster come listen port: $listen_port"
	else
	    if [[ -n "$ssl_port" ]]; then
	        ssl_enabled=${ssl_enabled:-false}
	        protocol="t3s"
	        listen_port="$ssl_port"
	    else
	        ssl_enabled="false"
	        protocol=""
	        listen_port=""
	    fi
	fi
		
	[ -z "$listen_address" ] && listen_address="0.0.0.0"


	echo "Encrypted User: $username"
	echo "Encrypted Password: $password"
	echo "Admin server name  : $admin_name"
	echo "Listen address     : $listen_address"
	echo "Listen port        : $listen_port"
	echo "Multicast port     : $cluster_multicast_port"
	echo "Clear enabled      : $listen_port_enabled"
	echo "SSL enabled        : $ssl_enabled"
	echo "Protocol           : $protocol"
	echo "Trust_Keystore     : $trust_keystore"
}

main() {
	find_setDomainEnv="$(find /u01/app/oracle/admin/*/aserver/ -type f -name setDomainEnv.sh)"
	
	while IFS= read -r setdomainenv; do
		set +u
		source "$setdomainenv"
		set -u
	
		local find_bootproperties
		find_bootproperties="$(find "${DOMAIN_HOME}" -type f -name boot.properties)"
	
		source "$find_bootproperties"
		export username
		export password
	
		cd "$LONG_DOMAIN_HOME"
	
		local config_xml="$LONG_DOMAIN_HOME/config/config.xml"
	
		xml_grab "$config_xml"
	
	
		
	done <<< "$find_setDomainEnv"

	report_data
	exec_wlst
}

main
