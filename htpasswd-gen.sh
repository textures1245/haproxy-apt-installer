#!/bin/bash
# Usage:
#   ./htpasswd-gen.sh users.csv > userlist.txt
#   or: ./htpasswd-gen.sh > userlist.txt   (for prompt input)
# CSV format: username,password

if ! command -v htpasswd >/dev/null 2>&1; then
    echo "Error: 'htpasswd' command not found. Please install apache2-utils or httpd-tools."
    exit 1
fi

# Function to output in HAProxy userlist format
gen_userlist_line() {
    local username="$1"
    local password="$2"
    echo "user $username password $password"
}

if [[ $# -eq 0 ]]; then
    echo "Paste your CSV lines (username,password), then press Ctrl-D when done:"
    while IFS=, read -r username password; do
        # Skip header or empty lines
        if [[ "$username" == "username" ]] || [[ -z "$username" ]] || [[ -z "$password" ]]; then
            continue
        fi
        hash=$(htpasswd -nbB "$username" "$password" | cut -d: -f2-)
        gen_userlist_line "$username" "$hash"
    done
    exit 0
fi

CSV_FILE="$1"

while IFS=, read -r username password; do
    # Skip header or empty lines
    if [[ "$username" == "username" ]] || [[ -z "$username" ]] || [[ -z "$password" ]]; then
        continue
    fi
    hash=$(htpasswd -nbB "$username" "$password" | cut -d: -f2-)
    gen_userlist_line "$username" "$hash"
done < "$CSV_FILE"
