#!/bin/bash#
# Generate iOS Custom.xcconfig
# Usages:
# - $bash generate_ios_custom_config.sh <google_service_info_plist_file_path> <output_dir>
#
plist="$1"
output_dir="$2"
custom_xcconfig="$output_dir/Custom.xcconfig"

client_id=$(/usr/libexec/PlistBuddy -c "Print :CLIENT_ID" "$plist")
reverse_client_id=$(/usr/libexec/PlistBuddy -c "Print :REVERSED_CLIENT_ID" "$plist")

echo "// This is a generated file; do not edit or check into version control." > "$custom_xcconfig"
echo "GOOGLE_CLIENT_ID=$client_id" >> "$custom_xcconfig"
echo "GOOGLE_REVERSE_CLIENT_ID=$reverse_client_id" >> "$custom_xcconfig"
