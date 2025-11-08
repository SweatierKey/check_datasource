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
	local xpath_expr xmldata

	# Ottieni nome AdminServer
	admin_name=$(xmllint --xpath "string(//*[local-name()='admin-server-name'])" "$config_xml" 2>/dev/null || true)

	if [[ -z "$admin_name" ]]; then
		echo "Errore: admin-server-name non trovato in $config_xml" >&2
		exit 1
	fi

	# Costruisci l'espressione XPath tutta su una riga (niente newline o apici singoli)
	xpath_expr="concat(
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='listen-address']
	| //*[local-name()='admin-server']/*[local-name()='listen-address']), '|',
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='listen-port-enabled']
	| //*[local-name()='admin-server']/*[local-name()='listen-port-enabled']), '|',
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='listen-port']
	| //*[local-name()='admin-server']/*[local-name()='listen-port']), '|',
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='ssl']/*[local-name()='enabled']), '|',
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='ssl']/*[local-name()='listen-port']), '|',
	string(//*[local-name()='server'][*[local-name()='name']='$admin_name']/*[local-name()='custom-trust-key-store-file-name']), '|',
	string(//*[local-name()='cluster']/*[local-name()='multicast-port'])
	)"

	# Esegui xmllint in modo sicuro, cattura l’output
	if ! xmldata=$(xmllint --xpath "$xpath_expr" "$config_xml" 2>/dev/null); then
		echo "Errore: xmllint non ha trovato i nodi attesi in $config_xml" >&2
		exit 1
	fi

	# Parsing in variabili
	IFS='|' read -r \
		listen_address \
		listen_port_enabled \
		clear_port \
		ssl_enabled \
		ssl_port \
		trust_keystore \
		cluster_multicast_port <<< "$xmldata"
	}

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
			"$chosen_listen_port")

		if [[ -f "$wlst" ]]; then
			if [[ -n "$trust_keystore" ]]; then
				export JAVA_OPTIONS="${java_options[@]}"
				"$wlst" "${args[@]}"
			else
				"$wlst" "${args[@]}"
			fi
		else
			if [[ -n "$trust_keystore" ]]; then
				java "${java_options[@]}" weblogic.WLST "${args[@]}"
			else
				java weblogic.WLST "${args[@]}"
			fi
		fi
	}

	report_data() {
		chosen_listen_port=""
		protocol=""

		if [[ "$listen_port_enabled" == true ]]; then
			if [[ -n "$cluster_multicast_port" ]]; then
				chosen_listen_port="$cluster_multicast_port"
				protocol="t3"
			else
				chosen_listen_port="${clear_port:-7001}"
				protocol="t3"
			fi
		else
			# listen_port_enabled false o non settato → ignoriamo cluster_multicast_port
			if [[ "$ssl_enabled" == true ]]; then
				chosen_listen_port="$ssl_port"
				protocol="t3s"
			else
				chosen_listen_port=""
				protocol=""
			fi
		fi

	# Default listen address
	[ -z "$listen_address" ] && listen_address="0.0.0.0"

	# Stampa dei dati
	echo "Encrypted User     : $username"
	echo "Encrypted Password : $password"
	echo "Admin server name  : $admin_name"
	echo "Listen address     : $listen_address"
	echo "Trust_Keystore     : $trust_keystore"
	echo "Clear Port         : $clear_port"
	echo "SSL Port           : $ssl_port"
	echo "Multicast port     : $cluster_multicast_port"
	echo "Clear enabled      : $listen_port_enabled"
	echo "SSL enabled        : $ssl_enabled"
	echo "Chosen Listen port : $chosen_listen_port"
	echo "Protocol           : $protocol"
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

		report_data
		exec_wlst
	done <<< "$find_setDomainEnv"
}

main
