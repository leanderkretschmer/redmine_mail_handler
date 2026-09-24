#!/usr/bin/env bash
# Loescht Redmine-Kommentare (Journals) nacheinander ueber die REST-API.
#
# Redmine hat keinen DELETE-Endpunkt fuer Journals. Ein Journal ohne
# Eigenschaftsaenderungen wird aber von Redmine geloescht, sobald seine Notiz
# per PUT /journals/:id.json auf leer gesetzt wird (JournalsController#update:
# "@journal.destroy if @journal.details.empty? && @journal.notes.blank?").
# Genau das macht dieses Skript fuer jede ID aus der Liste.
#
# Aufruf:
#   tools/delete_journals_via_api.sh IDS_DATEI [BASIS_URL] [--dry-run]
#
#   IDS_DATEI  Textdatei mit einer Journal-ID pro Zeile (Leerzeilen und
#              Zeilen mit # werden uebersprungen)
#   BASIS_URL  Redmine-URL, Standard: https://pm.cratchmere.com
#   --dry-run  nur anzeigen, nichts aendern
#
# Der API-Key wird beim Start abgefragt (Eingabe unsichtbar). Der Benutzer
# des Keys braucht das Recht, die Kommentare zu bearbeiten (Admin oder
# "Kommentare bearbeiten" in den betroffenen Projekten).
#
# Ergebnis je ID wird in eine Log-Datei neben der IDS_DATEI geschrieben.

set -euo pipefail

IDS_FILE="${1:-}"
BASE_URL="https://pm.cratchmere.com"
DRY_RUN=0
for arg in "${@:2}"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *) BASE_URL="${arg%/}" ;;
    esac
done

if [ -z "$IDS_FILE" ] || [ ! -f "$IDS_FILE" ]; then
    echo "Aufruf: $0 IDS_DATEI [BASIS_URL] [--dry-run]" >&2
    exit 1
fi

mapfile -t IDS < <(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$IDS_FILE" | grep -oE '[0-9]+')
if [ "${#IDS[@]}" -eq 0 ]; then
    echo "Keine Journal-IDs in $IDS_FILE gefunden." >&2
    exit 1
fi

echo "Redmine:   $BASE_URL"
echo "IDs:       ${#IDS[@]} Kommentare aus $IDS_FILE"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Modus:     DRY-RUN (es wird nichts geaendert)"
    printf '  wuerde loeschen: Journal %s\n' "${IDS[@]}" | head -20
    [ "${#IDS[@]}" -gt 20 ] && echo "  ... und $(( ${#IDS[@]} - 20 )) weitere"
    exit 0
fi

read -r -s -p "Redmine API-Key: " API_KEY
echo
if [ -z "$API_KEY" ]; then
    echo "Kein API-Key eingegeben, Abbruch." >&2
    exit 1
fi

# Key pruefen
me_status=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Redmine-API-Key: $API_KEY" "$BASE_URL/users/current.json")
if [ "$me_status" != "200" ]; then
    echo "API-Key wird von $BASE_URL nicht akzeptiert (HTTP $me_status), Abbruch." >&2
    exit 1
fi
me_login=$(curl -s -H "X-Redmine-API-Key: $API_KEY" "$BASE_URL/users/current.json" | sed -n 's/.*"login":"\([^"]*\)".*/\1/p')
echo "Angemeldet als: ${me_login:-unbekannt}"

read -r -p "Wirklich ${#IDS[@]} Kommentare unwiderruflich loeschen? [ja/NEIN] " CONFIRM
[ "$CONFIRM" = "ja" ] || { echo "Abgebrochen."; exit 0; }

LOG_FILE="${IDS_FILE%.*}_delete_$(date +%Y%m%d-%H%M%S).log"
ok=0; fail=0
for id in "${IDS[@]}"; do
    status=$(curl -s -o /tmp/delete_journal_resp.$$ -w '%{http_code}' \
        -X PUT \
        -H "X-Redmine-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        --data '{"journal":{"notes":""}}' \
        "$BASE_URL/journals/$id.json")
    if [ "$status" = "204" ] || [ "$status" = "200" ]; then
        ok=$((ok + 1))
        printf 'OK    %s HTTP %s\n' "$id" "$status" | tee -a "$LOG_FILE"
    else
        fail=$((fail + 1))
        printf 'FEHLER %s HTTP %s %s\n' "$id" "$status" "$(tr -d '\n' < /tmp/delete_journal_resp.$$ | cut -c1-120)" | tee -a "$LOG_FILE"
    fi
    sleep 0.2
done
rm -f /tmp/delete_journal_resp.$$

echo
echo "Fertig: $ok geloescht, $fail fehlgeschlagen. Log: $LOG_FILE"
[ "$fail" -eq 0 ]
