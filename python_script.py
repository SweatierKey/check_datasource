import sys
from weblogic.security.internal import *
from weblogic.security.internal.encryption import *

# --- Decrypt WLST credentials ---
encryptionService = SerializedSystemIni.getEncryptionService(".")
clearOrEncryptService = ClearOrEncryptedService(encryptionService)

if len(sys.argv) < 6:
    print "Uso: decrypt.py <encrypted_username> <encrypted_password> <protocol> <listen_address> <listen_port>"
    sys.exit(1)

encrypted_username = sys.argv[1].replace("\\", "")
encrypted_password = sys.argv[2].replace("\\", "")
protocol = sys.argv[3]
listen_address = sys.argv[4]
listen_port = sys.argv[5]

username = clearOrEncryptService.decrypt(encrypted_username)
password = clearOrEncryptService.decrypt(encrypted_password)
connect_url = "%s://%s:%s" % (protocol, listen_address, listen_port)

# --- Colori ANSI ---
GREEN = "\033[32m"
RED = "\033[31m"
RESET = "\033[0m"

# --- Connessione ---
connect(username, password, connect_url)
print "Connected to %s" % connect_url

servers = domainRuntimeService.getServerRuntimes()
if not servers:
    print "Nessun server in esecuzione o connessione non riuscita."
    disconnect()
    sys.exit(1)

# --- Raccolta risultati ---
results = {}          # {server_name: {ds_name: status}}
all_datasources = []
servers_without_jdbc = []

for server in servers:
    server_name = server.getName()
    results[server_name] = {}
    jdbcServiceRT = server.getJDBCServiceRuntime()
    if not jdbcServiceRT:
        servers_without_jdbc.append(server_name)
        continue

    datasources = jdbcServiceRT.getJDBCDataSourceRuntimeMBeans()
    if not datasources:
        servers_without_jdbc.append(server_name)
        continue

    for ds in datasources:
        ds_name = ds.getName()
        if ds_name not in all_datasources:
            all_datasources.append(ds_name)
        try:
            ds.testPool()
            results[server_name][ds_name] = "OK"
        except:
            results[server_name][ds_name] = "FAIL"

all_datasources.sort()
server_names = results.keys()
server_names.sort()

# --- Parametri tabella ---
MAX_DS_PER_ROW = 4
server_col_width = 20
ds_col_width = 16  # aumentato per più spazio

for ds in all_datasources:
    if len(ds) + 4 > ds_col_width:  # 4 spazi extra
        ds_col_width = len(ds) + 4

# --- Stampa tabella con wrapping ---
print "\n===== DATASOURCE HEALTH TABLE ====="
for start in range(0, len(all_datasources), MAX_DS_PER_ROW):
    ds_block = all_datasources[start:start + MAX_DS_PER_ROW]

    # intestazione
    header = "%-*s" % (server_col_width, "Server")
    for ds_name in ds_block:
        header += " %-*s" % (ds_col_width, ds_name)
    print header

    # separatore
    print "-" * (server_col_width + (ds_col_width + 1) * len(ds_block))

    # righe per server
    for server_name in server_names:
        line = "%-*s" % (server_col_width, server_name)
        for ds_name in ds_block:
            status = results[server_name].get(ds_name, "-")
            if status == "OK":
                val = GREEN + "OK" + RESET
            elif status == "FAIL":
                val = RED + "FAIL" + RESET
            else:
                val = "-"
            padding = " " * (ds_col_width - len(status))
            line += " " + val + padding
        print line

    print "=" * (server_col_width + (ds_col_width + 1) * len(ds_block))

# --- Riepilogo finale per server ---
print "\n===== SUMMARY ====="
exit_code = 0
for server_name in server_names:
    ok_count = 0
    fail_count = 0
    for ds_name in all_datasources:
        status = results[server_name].get(ds_name)
        if status == "OK":
            ok_count += 1
        elif status == "FAIL":
            fail_count += 1
    total = ok_count + fail_count
    if total > 0:
        summary = "%d/%d OK" % (ok_count, total)
    else:
        summary = "N/A"

    if fail_count > 0:
        print "%-20s %s%-10s%s (%d FAIL)" % (server_name, RED, summary, RESET, fail_count)
        exit_code = 1
    else:
        print "%-20s %s%-10s%s" % (server_name, GREEN, summary, RESET)

if servers_without_jdbc:
    print "\nServer senza JDBC attivi: %s" % ", ".join(servers_without_jdbc)

print "====================="

disconnect()
sys.exit(exit_code)