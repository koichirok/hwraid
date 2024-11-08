#!/bin/bash
# $Id: megaclisas-status,v 1.78 2018/10/01 03:52:57 root Exp root $
#
# Written by Adam Cecile <gandalf@NOSPAM.le-vert.net>
# Modified by Vincent S. Cojot <vincent@NOSPAM.cojot.name>
# Rewritten in shll by KIKUCHI Koichiro <koichiro.hataki.jp@gmail.com>

: "${MEGA_CLI_PATH}"

# Number of lines (=fields) per disk returned by returnDiskInfo
DISKINFO_FIELD_COUNT=11
UNCONF_DISKINFO_FIELD_COUNT=10

# Non-Nagios Mode defaults
: "${NAGIOS_MODE:=0}"
NAGIOS_GOOD_ARRAY=0
NAGIOS_BAD_ARRAY=0
NAGIOS_GOOD_DISK=0
NAGIOS_BAD_DISK=0

# Sane defaults
: "${PRINT_ARRAY:=1}"
: "${PRINT_CONTROLLER:=1}"
: "${DEBUG_MODE:=0}"
: "${NO_TEMP_MODE:=0}"

declare -A NestedLDTable
# Outputs is a 'dict' of all MegaCLI outputs so we can re-use them during loops..
CACHEDIR=

#
# Functions
#

dbgprint() {
    if ((DEBUG_MODE)); then
        echo "# DEBUG (${BASH_LINENO[1]}) : $1" >&2
    fi
}

# Get and cache command output
getOutput() {
    local cachefile lines
    cachefile="$CACHEDIR/cmd::${*//[^a-zA-Z0-9]/_}"

    if [ -f "$cachefile" ]; then
        dbgprint "Got Cached value: $*"
        # read the cached value (cachefile's after the first line)
        lines="$(tail -n +2 "$cachefile")"
    else
        dbgprint "Not a Cached value: $*"
        echo "$*" > "$cachefile"
        lines="$("$@")"
        # sanitize the output. Remove the leading carriage return
        lines="${lines#$'\r'}"
        echo "$lines" >> "$cachefile"
    fi
    echo "$lines"
}

dbgShowCmdCache() {
    local cachefile
    for cachefile in "$CACHEDIR"/cmd::*; do
        (printf "Cached command: "; cat "$cachefile") | while IFS= read -r line; do
            dbgprint "$line"
        done
    done
}

megacli() {
    getOutput "$MEGA_CLI_PATH" "$@"
}

# Get and cache disks, make sure we don't count the same disk twice
AddDisk() {
    local cachefile="$CACHEDIR/disk::$1"
    local disk="$2"

    if [ -f "$cachefile" ] &&  grep -qFx "$disk" "$cachefile" > /dev/null 2>&1; then
        dbgprint "Disk: $disk Already present in $1 Disk Table"
        return 1
    else
        dbgprint "Confed $NAGIOS_GOOD_DISK/${NAGIOS_BAD_DISK} Disk: $disk Not already present in $1 Disk Table, adding"
        echo "$disk" >> "$cachefile"
        return 0
    fi
}

dbgShowDiskTableCache() {
    local cachefile="$CACHEDIR/disk::$1"
    local cache=""
    if [ -f "$cachefile" ]; then
        cache="$(< "$CACHEDIR/disk::$1")"
    fi
    dbgprint "Printing $1: ${cache//$'\n'/ }"
}

#######################################
# Return the number of controllers
# Arguments:
#   None
# Outputs:
#   The number of controllers
#######################################
countControllers() {
    local count
    count="$(megacli -adpCount -NoLog | grep -m 1 'Controller Count.*:')" || count=0
    count="$(trim "${count##*:}")"
    echo "${count%.}"
}

#######################################
# Count the number of physical drives on a controller
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The number of physical drives
#######################################
countDrives() {
    local count
    count="$(megacli -PDGetNum -a"$1" -NoLog | grep -m 1 "Number of Physical Drives on Adapter.*:")" || count=0
    trim "${count##*:}"
}

#######################################
# Return the rebuild progress of a drive
# Arguments:
#   $1: The controller ID which the drive belongs to
#   $2: The enclosure ID which the drive belongs to
#   $3: The slot ID of the drive
# Outputs:
#   The rebuild progress of the drive in percent
#######################################
returnRebuildProgress() {
    local controllerid="$1"
    local enclid="$2"
    local slotid="$3"
    local percent
    if percent="$(megacli -PDRbld -showprog -physdrv"[$enclid:$slotid]" -a"$controllerid" -NoLog \
                  | grep -m 1 "Rebuild Progress on Device at Enclosure.*, Slot .* Completed ")"; then
        percent="${percent##*Completed}"
        echo "${percent%%%*}"
    else
        echo 0
    fi
}

#######################################
# Count the number of configured drives (drives in arrays) on a controller
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The number of configured drives
#######################################
countConfDrives() {
    local controllerid="$1"
    local confdrives=0
    # Count the configured drives
    while read -r line; do
        name="$(trim "${line%%:*}")"
        value="$(trim "${line#*:}")"
        if [[ "$name" == "Enclosure Device ID" ]]; then
            enclid="${value}"
        elif [[ "$name" == "Slot Number" ]]; then
            slotid="${value}"
            if AddDisk CONF_DISKS "${controllerid}${enclid:-"N/A"}${slotid:-"N/A"}"; then
                confdrives=$((confdrives + 1))            
            fi
        fi
    done < <(megacli -LdPdInfo -a"$controllerid" -NoLog)
    echo "$confdrives"
}

#######################################
# Count the number of unconfigured and hotspare drives on a controller
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The number of unconfigured and hotspare drives
#######################################
countUnconfDrives() {
    megacli -PDList -a"$1" -NoLog | grep -cE "^Firmware state: (Unconfigured|Hotspare)"
}

#######################################
# Count the number of arrays (logical drives) on a controller
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The number of arrays
#######################################
countArrays() {
    megacli -LDInfo -lall -a"$1" -NoLog | grep -cE "^(CacheCade )?Virtual Drive:"
}

#######################################
# Return the the controller's PCI path
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The controller's PCI path in the format "0000:xx:yy.z"
#######################################
returnHBAPCIInfo() {
    local controllerid="$1"
    local -A pciinfo
    local pcipath

    while read -r line; do
        if [[ "$line" == *:* ]]; then
            pciinfo["$(trim "${line%%:*}")"]="$(trim "${line#*:}")"
        fi
    done < <(megacli -AdpGetPciInfo -a"${controllerid}" -NoLog)

    pcipath="$(printf '0000:%02d:%02d.%01d\n' "${pciinfo["Bus Number"]}" "${pciinfo["Device Number"]}" "${pciinfo["Function Number"]}")"
    dbgprint "Array PCI path : $pcipath"
    echo "$pcipath"
}

#######################################
# Perform floating-point arithmetic calculations
# Arguments:
#   $1: The expression to calculate
# Outputs:
#   The result of the calculation if a floating-point calculator is found,
#   otherwise the expression itself
#######################################
calc() {
    local exp="$1"
    if command -v bc >/dev/null 2>&1; then
        echo "$exp" | bc
    elif command -v awk >/dev/null 2>&1; then
        awk "BEGIN { print $* }"
    elif command -v zsh >/dev/null 2>&1; then
        zsh -c "echo \$(($exp))"
    elif command -v perl >/dev/null 2>&1; then
        perl -e "print $exp"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "print($exp)"
    else
        echo "No floating point support calculator found" >&2
        echo "$exp"
    fi
}

#######################################
# Parse the MegaCli's -AdpAllInfo output and return the controller's information
# Arguments:
#   $1: The controller ID to query
# Outputs:
#   The controller's information in 6 lines:
#   - Controller ID
#   - Product Name
#   - Memory Size
#   - ROC temperature
#   - BBU status
#   - Firmware version
#######################################
returnHBAInfo() {
    local id="$1"
    local section
    local -A hbainfo

    while read -r line; do
        if [ -z "$line" ] || [[ "$line" =~ ^=+$ ]]; then
            continue
        elif [[ "$line" == *:* ]]; then
            hbainfo["$section/$(trim "${line%%:*}")"]="$(trim "${line#*:}")"
        else
            section="$line"
        fi
    done < <(megacli -AdpAllInfo -a"$id" -NoLog)

    # Print the results
    # 1-3: Controller ID, Product Name, Memory Size
    section="HW Configuration"
    echo "c$id" 
    echo "${hbainfo["Versions/Product Name"]}"
    echo "${hbainfo["$section/Memory Size"]:-Unknown}"
    # 4: ROC temperature
    if ((NO_TEMP_MODE)) || [ "${hbainfo["$section/Temperature sensor for ROC"]}" = "Absent" ]; then
        echo "N/A"
    else
        echo "${hbainfo["$section/ROC temperature"]%% *}C"
    fi
    # 5: BBU status
    if [ "${hbainfo["$section/BBU"]}" = "Present" ]; then
        if [ "$(getBbuStatus "$id" "BBU Firmware Status/Battery Replacement required")" = "Yes" ]; then
            echo "REPL"
        else
            echo "Good"
        fi
    else
        echo "${hbainfo["$section/BBU"]}"
    fi
    # 6: Firmware version
    echo "FW: ${hbainfo["Versions/FW Package Build"]:-Unknown}"
}

#######################################
# Parse the MegaCli's `-AdpBbuCmd -GetBbuStatus` output and return the specified field(s)
# Arguments:
#   $1: The controller ID to query
#   $2...: The field(s) to return
# Outputs:
#   The new line-separated value(s) of the specified field(s)
#######################################
getBbuStatus() {
    local controllerid="$1"
    shift
    local line key section value
    local -A bbustatus

    while IFS= read -r line; do
        if [[ "$line" =~ ^\ *[^\ ].*:.* ]]; then
            key="$(trim "${line%%:*}")"
            value="$(trim "${line#*:}")"
            if [[ "$line" == "  "* ]]; then
                key="${section}/${key}"
            elif [ -z "$value" ]; then
                section="$key"
            fi
            bbustatus["$key"]="$value"
        elif [ "${line// /}" ]; then
            if [ "$key" = "Battery State" ]; then
                bbustatus["$key"]+="$line"
            else
                echo "Unexpected line: $line" >&2
            fi
        fi
    done < <(megacli -AdpBbuCmd -GetBbuStatus -a"$controllerid" -NoLog)

    for key in "$@"; do
        if [ "${bbustatus["$key"]}" ]; then
            echo "${bbustatus["$key"]}"
        else
            echo "BBU Status does not have key: $key" >&2
        fi
    done
}

#######################################
# Remove leading and trailing whitespaces from a string
# Arguments:
#   $1: The string to trim
# Outputs:
#   The trimmed string
#######################################
trim() {
    local str="$1"
    str="${str#"${str%%[![:space:]]*}"}" # remove leading spaces
    echo "${str%"${str##*[![:space:]]}"}" # remove trailing spaces
}

#######################################
# Parse the MegaCli's -LDInfo output and return the array's information
# Arguments:
#   $1: The controller ID to query
#   $2: The array ID to query
returnArrayInfo() {
    local controllerid="$1"
    local arrayid="$2"
    local arrayindex="$3"
    local line name value raidlvl raidtype id
    local -A ldinfo

    while read -r line; do
        if [ "$line" = "Adapter ${controllerid} -- Virtual Drive Information:" ]; then
            continue
        elif [[ "$line" == *:* ]]; then
            name="$(trim "${line%%:*}")"
            value="$(trim "${line#*:}")"

            if [[ "$name" =~ (CacheCade\ )?Virtual\ Drive ]]; then
                # single array info starts here, ends next blank line
                ldinfo=([number]="${value%% *}" ["Target Id"]="${value##*: }")
                ldinfo["Target Id"]="${ldinfo["Target Id"]%)}"
                if [ "${ldinfo["Target Id"]}" != "$arrayid" ]; then
                    echo "Unexpected condition: ${ldinfo["Target Id"]} != $arrayid ($line)" >&2
                fi
            elif ((${#ldinfo[@]})); then
                ldinfo["$name"]="$value"
            fi
        elif ((${#ldinfo[@]})); then
            raidtype="$(parseRaidLevel "$controllerid" "$arrayindex" "${ldinfo["RAID Level"]}" "${ldinfo["Span Depth"]}" "${ldinfo["Disk per Span"]}")"
            # print results in this order:
            #   1: ID, 2: Type, 3: Size, 4: Strip Size, 5: Cache Policy, 6: Disk Cache Policy,
            #   7: State, 8: Target Id, 9: Cache Cade info, 10: Ongoing Progress
            echo "c${controllerid}u${arrayid}"
            echo "$raidtype"
            parseLdSize "${ldinfo["Size"]}"
            echo "${ldinfo["Strip Size"]}"
            parseLdCachePolicy "${ldinfo["Current Cache Policy"]}"
            parseLdDiskCachePolicy "${ldinfo["Disk Cache Policy"]}"
            echo "${ldinfo["State"]:-"N/A"}"
            echo "${ldinfo["Target Id"]}"
            # Cache Cade info
            if [ "${ldinfo["Cache Cade Type"]}" ]; then
                echo  "Type: ${ldinfo["Cache Cade Type"]}"
            else
                parseLdTargetIdOftheAssociatedLDs "$controllerid" "${ldinfo["Target Id of the Associated LDs"]}"
            fi
            # Ongoing Progress
            [ "${ldinfo["Ongoing Progress"]}" ] && echo "$name : ${ldinfo["Ongoing Progresses"]}" || echo None
            ldinfo=()
        fi
    done < <(megacli -LDInfo -l"$arrayid" -a"$controllerid" -NoLog)
}

parseRaidLevel() {
    local id="c${1}u${2}"
    local level str
    local spandepth="${4:-0}"
    local diskperspan="${5:-0}"
    # Primary-0, Secondary-0, RAID Level Qualifier-0 -> (0, 0, 0)
    while read -r str; do
        level+=("${str##*-}")
    done <<<"${3//, /$'\n'}"

    # Compute the RAID level
    if ((${#level[@]} == 0)); then
        str="N/A"
    elif ((spandepth > 1)); then
        # If Span Depth is greater than 1 chances are we have a RAID 10, 50 or 60
        str="RAID-${level[0]}0"
        NestedLDTable["${id}"]=1
    else
        str="RAID-${level[0]}"
        if ((raidlvl[0] == 1)) && ((diskperspan > 2)); then
            #                                   ^^^ Is this correct?
            str+="0" # RAID-10
            NestedLDTable["${id}"]=1
        fi
    fi
    dbgprint "RAID Level: ${level[0]} Span Depth: $spandepth Disk Per Span: $diskperspan Raid Type: $str"
    echo "$str"
}

parseLdSize() {
    read -r -a size <<<"$1"
    case "${size[1]}" in
        MB)
            if ((size[0] > 1000)); then
                printf "%.0fG\n" "$(calc "${size[0]} / 1000.0")"
            else
                parintf "%.0fM\n" "${size[0]}"
            fi
            ;;
        TB) printf "%.0fG\n" "$(calc "${size[0]} * 1000.0")";;
        *)  printf "%.0fG\n" "${size[0]}";;
    esac
}

parseLdCachePolicy() {
    case "$1" in
        *ReadAdaptive*)  printf "ADRA";;
        *ReadAheadNone*) printf "NORA";;
        *ReadAhead*)     printf "RA";;
    esac
    case "$1" in
        *WriteBack*)    echo ",WB" ;;
        *WriteThrough*) echo ",WT" ;;
        *)              echo;;
    esac
}

parseLdDiskCachePolicy() {
    case "$1" in
        Enabled|Disabled) echo "1" ;;
        *Disk\'s\ Default*) echo "Default" ;;
        *) echo "N/A" ;;
    esac
}

parseLdTargetIdOftheAssociatedLDs() {
    local controllerid="$1"
    local lds id

    while read -r id; do
        if [ "$id" -eq "$id" ] 2>/dev/null; then
            lds+="${lds:+, }c${controllerid}u$id"
        fi
    done <<<"${2//,/$'\n'}"

    if [ "$lds" ]; then
        echo "Associated : $lds"
    else
        echo "None"
    fi
}

processArrays() {
    local controllercount="$1"
    local ldid ldcount controllerid pcipath arraynumber i
    local printdata=("-- ID" "Type" "Size" "Strpsz" "Flags" "DskCache" "Status" "OS Path" "CacheCade" "InProgress")
    local flen=(5 4 7 7 5 8 8 8 10 12)

    for ((controllerid=0; controllerid < controllercount; controllerid++)); do
        pcipath="$(returnHBAPCIInfo "$controllerid")"
        arraynumber="$(countArrays "$controllerid")"

        # We need to explore each HBA to look for gaps in LD's
        ldid=0
        ldcount=0

        while ((ldcount < arraynumber)); do
            while read -r line; do
                if [[ "$line" =~ ^Adapter.*Virtual\ Drive\ .*\ Does\ not\ Exist ]]; then
                    ((ldid++))
                elif [[ "$line" =~ ^(CacheCade\ )?Virtual\ Drive:.* ]]; then
                    mapfile -t arrayinfo < <(returnArrayInfo "$controllerid" "$ldid" "$ldcount")
                    ((ldcount++, ldid++))

                    if [ "$pcipath" ]; then
                        arrayinfo[7]="$(findRealDiskDeviceByPath "$pcipath" "${arrayinfo[7]}")"
                    else
                        arrayinfo[7]="N/A"
                    fi
                    printdata+=("${arrayinfo[@]}")

                    dbgprint "Array state : LD ${arrayinfo[0]}, status : ${arrayinfo[6]}"
                    if [ "${arrayinfo[6]}" != "Optimal" ] && [ "${arrayinfo[6]}" != "N/A" ]; then
                        ((NAGIOS_BAD_ARRAY++))
                    else
                        ((NAGIOS_GOOD_ARRAY++))
                    fi
                    for i in 1 4 8; do
                        ((${#arrayinfo[$i]} > ${flen[$i]})) && flen[i]="${#arrayinfo[$i]}"
                    done
                fi
            done < <(megacli -LDInfo -l"$ldid" -a"$controllerid" -NoLog)
        done
    done

    if ((PRINT_ARRAY)) && ((! NAGIOS_MODE)); then
        echo "-- Array information --"
        ldfmt="$(printf '%%-%ds | %%-%ds | %%%ds | %%%ds | %%%ds | %%%ds | %%%ds | %%%ds | %%-%ds |%%-%ds\\n' "${flen[@]}")"
        # shellcheck disable=SC2059
        printf "$ldfmt" "${printdata[@]}"
        echo
    fi
}

returnDiskInfo() {
    local controllerid="$1"
    local line enclid drvpos fstate percent name value model
    local -A pdinfo
    local arrayindex=-1
    local consecutive_blanks=0

    while read -r line; do
        if [ "$line" ]; then
            consecutive_blanks=0
            name="$(trim "${line%%:*}")"
            value="$(trim "${line#*:}")"
            if [[ "$name" =~ (CacheCade\ )?Virtual\ D(rive|isk) ]]; then
                ((arrayindex++))
                # If we need LD information, we can get it between here and the next "Span: ..." line
            elif [ "$name" = PD ]; then
                pdinfo["$name"]="${value% Information}"
            elif ((${#pdinfo[@]})); then
                # collect data only between "PD: X Information" and consecutive blank lines
                pdinfo["${name}"]="$value"
            fi
        else
            if ((++consecutive_blanks < 2)) || ((${#pdinfo[@]} == 0)); then
                continue
            elif [ "${pdinfo["Inquiry Data"]}" ]; then
                enclid="${pdinfo["Enclosure Device ID"]/N\/A/}"
                mapfile -t fstate < <(parseFiremareState "${pdinfo["Firmware state"]}")
                dbgprint "Firmware State: ${fstate[*]}"
                # FIXME: field name can be other than "Drive's position" in some cases
                mapfile -t drvpos < <(parseDrivePosition "${pdinfo["Drive's position"]}")
                dbgprint "Disk Info: ${drvpos[0]} ${pdinfo[PD]} ${pdinfo["Enclosure Device ID"]}"

                # print results in 11 fields
                if [ "${NestedLDTable["c${controllerid}u${arrayindex}"]}" ] && [ "${drvpos[1]}" ]; then
                    # drvpos[1] is the Span ID, we need to add it to the arrayid
                    echo "${drvpos[0]}s${drvpos[1]}"
                else
                    echo "${drvpos[0]}"
                fi
                echo "${pdinfo["PD"]}"
                parseMediaType "${pdinfo["Media Type"]}"
                mapfile -t model < <(parseInquiryData "${pdinfo["Inquiry Data"]}" "${pdinfo["Device Firmware Level"]}")
                echo "${model[*]}"
                parseDiskSize "${pdinfo["Coerced Size"]}"
                if [ "${fstate[1]}" = "Rebuild" ]; then
                    echo "Rebuilding ($(returnRebuildProgress "$controllerid" "$enclid" "${pdinfo["Slot Number"]}")%)"
                else
                    echo "${fstate[0]:-Offline}"
                fi
                echo "${pdinfo["Device Speed"]:-"Unknown"}"
                parseDriveTemperature "${pdinfo["Drive Temperature"]}"
                echo "$enclid"
                echo "${pdinfo["Slot Number"]}"
                echo "${pdinfo["Device Id"]:-"Unknown"}"
            fi
            pdinfo=()
        fi
    #### BUG: -LdPdInfo shows all PD on the adapter, not just for the LD we wanted..
    #### while arrayid <= arraynumber:
    done < <(megacli -LdPdInfo -a"$controllerid" -NoLog)
}

processDisks() {
    local controllercount="$1"
    local controllerid drivecount dlen mlen flen arraydisk array diskname
    local printdata=("-- ID" "Type" "Drive Model" "Size" "Status" "Speed" "Temp" "Slot ID" "LSI ID")

    for ((controllerid=0; controllerid < controllercount; controllerid++)); do
        drivecount="$(countDrives "$controllerid")"
        ((drivecount)) || continue

        mapfile -t arraydisk < <(returnDiskInfo "$controllerid")

        while ((${#arraydisk[@]})); do
            array=("${arraydisk[@]:0:DISKINFO_FIELD_COUNT}")
            arraydisk=("${arraydisk[@]:DISKINFO_FIELD_COUNT}")

            diskname="$controllerid${array[8]}${array[9]}"
            dbgprint "Disk c$diskname status : ${array[5]}"
            if [[ "${array[5]}" =~ ^Online$|^Online,\ Spun\ Up$|^Rebuilding\ \(.* ]]; then
                AddDisk NAGIOS_GOOD_DISKS "$diskname" && ((NAGIOS_GOOD_DISK++))
            else
                AddDisk NAGIOS_BAD_DISKS "$diskname" && ((NAGIOS_BAD_DISK++))
            fi
            printdata+=("c${controllerid}u${array[0]}p${array[1]}")
            printdata+=("${array[@]:2:6}" "[${array[8]}:${array[9]}]" "${array[10]}")
            ((${#array[0]} > ${dlen:-0})) && dlen="${#array[0]}"
            ((${#array[3]} > ${mlen:-${#printdata[2]}})) && mlen="${#array[3]}"
            ((${#array[5]} > ${flen:-${#printdata[4]}})) && flen="${#array[5]}"
        done
    done
    if ((!NAGIOS_MODE)); then
        echo "-- Disk information --"
        # Adjust print format with width computed above
        drvfmt="%-$((dlen + 6))s | %-4s | %-${mlen}s | %-8s | %-${flen}s | %-8s | %-4s | %-8s | %-8s"
        # shellcheck disable=SC2059
        printf "$drvfmt\n" "${printdata[@]}"
        echo
    fi
}

# extract second item's value from  e.g. "DiskGroup: 4, Span: 0, Arm: 0"
parseDrivePosition() {
    grep -Eo '[0-9]+' <<<"$1"
}

parseDiskSize() {
    local value="${1%% [*}"  # Remove the [xxxx Sectors] part
    # Truncate to one decimal place. I'm not sure why GB is converted to Gb
    echo "${value/[0-9][0-9] GB/ Gb}"
}

#######################################
# Parse the value of "Firmware state" field.
# Arguments:
#   $1: The value of "Firmware state" field
# Outputs:
#   Parsed firmware state in 2 lines. Each line contains the state and simpified state respectively.
parseFiremareState() {
    local state="$1"
    echo "$state"
    trim "${state%%(*}" # Remove the " (.*)" part
}

#######################################
# Parse the value of "Inquiry Data" field.
# Arguments:
#   $1: The value of "Inquiry Data" field
#   $2: The firmware level typically found in the "Device Firmware Level" field
# Outputs:
#   Parsed inquiry data in 4 lines. Each line contains the Vendor, Product, Revision, and Serial respectively.
#   If the inquiry data is not recognized, the space-separated original inquiry data is returned.
#######################################
parseInquiryData() {
    local -a data
    local -A info
    local firmware_level="$2"
    dbgprint "Inquiry Data: $1, Firmware Level: $firmware_level"

    read -r -a data <<<"$1"
    ### Known Inquiry Data Formats ###
    # Others:
    if ((${#data[@]} == 3)); then
        if [ "$firmware_level" ] && [[ "${data[2]}" == "$firmware_level"* ]]; then
            dbgprint "DELL/IBM style inquiry data detected: ${data[*]}"
            # DELL/IBM: Vendor/Manufacturer SP+ Model SP+ FW Serial:
            #   SEAGATE ST9300603SS     FS666SE21PRZ
            #   HITACHI HUC103030CSS600 J516PDVGMVJE
            #   TOSHIBA MBF2300RC       DA06EB03PB5063DA
            #   WD      WD6001BKHG      D1S6WXH1E93ZRF49
            #   IBM     MK3001GRRB      62095360DG92620962096209
            info["Vendor"]="${data[0]}"
            info["Product"]="${data[1]}"
            info["Revision"]="$firmware_level"
            info["Serial"]="${data[2]#"$firmware_level"}"
        else
            for vendor in Hitach WDC TOSHIBA; do
                if [[ "${data[0]}" == *$vendor ]]; then
                    # Hitachi, WD, Toshiba: Serial Model Vendor SP Model SP+ FW:
                    #   PK2361PAGB31UWHitachi HUS724040ALE640                 MJAOA3B0
                    #   WD-WCAVY6576736WDC WD2002FYPS-02W3B0                   04.01G01
                    #   32NFP14ZTTOSHIBA MK5061GSYB                      ME0A    
                    dbgprint "Manufacturer style inquiry data detected: ${data[*]}"
                    info["Vendor"]="$vendor"
                    info["Product"]="${data[1]}"
                    info["Revision"]="${data[2]}"
                    info["Serial"]="${data[0]%$vendor}"
                    break
                fi
            done
        fi
    elif ((${#data[@]} == 2)); then
        if [[ "${data[0]}" == ????????ST* ]]; then
            dbgprint "Seagate style inquiry data detected: ${data[*]}"
            # Seagate: Serial Model SP+ FW
            #   Z1E19S2QST2000DM001-1CH164                      CC43
            #   6XW02738ST32000542AS                            CC32
            info["Vendor"]="SEAGATE"
            info["Product"]="${data[0]#????????}"
            info["Revision"]="${data[1]}"
            info["Serial"]="${data[0]%ST*}"
        elif [[ "${data[0]}" == NETAPP ]]; then
            dbgprint "NetApp style inquiry data detected: ${data[*]}"
            # NetApp: Vendor Model FW Serial
            #   NETAPP X410_HVIPC288A15NA01LVV48VZN
            info["Vendor"]="NETAPP"
            info["Product"]="${data[1]%"$firmware_level"*}"
            info["Revision"]="$firmware_level"
            info["Serial"]="${data[1]#*"$firmware_level"}"
        fi
    elif((${#data[@]} == 4)); then
        dbgprint "Intel style inquiry data detected: ${data[*]}"
        # INTEL:
        #   CVCV2515021D240CGN  INTEL SSDSC2CW240A3                     400i      
        info["Vendor"]="${data[1]}"
        info["Product"]="${data[2]}"
        info["Serial"]="${data[0]}"
        info["Revision"]="${data[3]}"
    fi
    if ((${#info[@]} == 4)); then
        dbgprint "Parsed Inquiry Data: Vendor: ${info["Vendor"]} Product: ${info["Product"]} Revision: ${info["Revision"]} Serial: ${info["Serial"]}"
        echo "${info["Vendor"]:-Unknown}"
        echo "${info["Product"]:-Unknown}"
        echo "${info["Revision"]:-Unknown}"
        echo "${info["Serial"]:-Unknown}"
    else
        dbgprint "No known inquiry data format detected: ${data[*]}"
        echo "${data[*]}"
    fi
}

#######################################
# Parse the value of "Media Type" field.
# Arguments:
#   $1: The value of "Media Type" field
# Outputs:
#   Achronym of the media type if it's recognized, otherwise "N/A"
#######################################
parseMediaType() {
    case "$1" in
        "Hard Disk Device") echo "HDD" ;;
        "Solid State Device") echo "SSD" ;;
        *) echo "N/A" ;;
    esac
}

#######################################
# Parse the value of "Drive Temperature" field.
# The value is in the format "xxC (xx.xx F)"
# Globals:
#   NO_TEMP_MODE
# Arguments:
#   $1: The value of "Drive Temperature" field
# Outputs:
#   N/A if NO_TEMP_MODE is true, otherwise the temperature in Celsius
#######################################
parseDriveTemperature() {
    ((NO_TEMP_MODE)) && echo "N/A" || echo "${1%% (*}"
}

returnUnconfDiskInfo() {
    local controllerid="$1"
    local line name value model fstate
    local consecutive_blanks=0
    local -A pdinfo

    while read -r line; do
        if [ "$line" ]; then
            consecutive_blanks=0
            name="$(trim "${line%%:*}")"
            value="$(trim "${line#*:}")"
            if [ "$name" = "Enclosure Device ID" ]; then
                # in -PDList output, the "Enclosure Device ID" field is the first field of a new disk
                pdinfo=(["$name"]="$value")
            elif ((${#pdinfo[@]})); then
                pdinfo["$name"]="$value"
            fi
        else
            if ((++consecutive_blanks < 2)) || ((${#pdinfo[@]} == 0)); then
                continue
            elif [ "${pdinfo["Drive's position"]}" ]; then
                # Unconfigured disk does not have "Drive's position" field. might be unreadable.
                # Note that recent bash supports `[[ -v array[key] ]]` to check if key exists, but it's not portable and
                # doesn't work with keys containing single quotes even in bash 5.1 (maybe a bug).
                :
            else
                mapfile -t model < <(parseInquiryData "${pdinfo["Inquiry Data"]}" "${pdinfo["Device Firmware Level"]}")
                mapfile -t fstate < <(parseFiremareState "${pdinfo["Firmware state"]}")
                dbgprint "Firmware State: ${fstate[0]} ${fstate[1]}"
                if [ "${fstate[1]}" = "Unconfigured" ]; then
                    dbgprint "Unconfigured Disk: Arrayid: N/A DiskId: ${pdinfo["Device Id"]} ${fstate[0]}"
                elif [ "${fstate[1]}" = "Online, Spun Up" ]; then
                    dbgprint "Online Unconfed Disk: Arrayid: N/A DiskId: ${pdinfo["Device Id"]} ${fstate[0]}"
                fi
                # print results in 10 fields
                [ "${pdinfo["Media Type"]}" ] && parseMediaType "${pdinfo["Media Type"]}" || echo "Unknown"
                echo "${model[*]}"
                [ "${pdinfo["Coerced Size"]}" ] && parseDiskSize "${pdinfo["Coerced Size"]}" || echo "Unknown"
                echo "${fstate[0]:-Offline}"
                echo "${pdinfo["Device Speed"]:-"Unknown"}"
                [ "${pdinfo["Drive Temperature"]}" ] && parseDriveTemperature "${pdinfo["Drive Temperature"]}" || echo "Unk0C"
                echo "${pdinfo["Enclosure Device ID"]/N\/A/}"
                echo "${pdinfo["Slot Number"]}"
                echo "${pdinfo["Device Id"]}"
                echo "N/A" # OS Path
            fi
            pdinfo=()
        fi
    done < <(megaclie -PDList -a"$controllerid" -NoLog)
}

processUnconfDisks() {
    local controllercount="$1"

    local totalconfdrivenumber=0
    local totalunconfdrivenumber=0
    local totaldrivenumber=0
    local pcipath controllerid arraydisk array mlen flen
    local printdata=("-- ID" "Type" "Drive Model" "Size" "Status" "Speed" "Temp" "Slot ID" "LSI ID" "Path")
    local mlen="${#printdata[2]}" # length of "Drive Model" column
    local flen="${#printdata[4]}" # length of "Status" column

    for ((controllerid=0; controllerid < controllercount; controllerid++)); do
        totalconfdrivenumber=$((totalconfdrivenumber + $(countConfDrives "$controllerid")))
        totaldrivenumber=$((totaldrivenumber + $(countDrives "$controllerid")))

        # Sometimes a drive will be reconfiguring without any info on that it is going through a rebuild process.
        # This happens when expanding an R{5,6,50,60} array, for example. In that case, totaldrivenumber will still be
        # greater than totalconfdrivenumber while countUnconfDrives(output) will be zero. The math below attempts to solve this.
        totalconfdrivenumber=$((totalconfdrivenumber + $(max "$(countUnconfDrives "$controllerid")" $((totaldrivenumber - totalconfdrivenumber)) ) ))
    done

    dbgprint "Total Drives in system : $totaldrivenumber"
    dbgprint "Total Configured Drives : $totalconfdrivenumber"
    dbgprint "Total Unconfigured Drives : $totalunconfdrivenumber"

    ((totalunconfdrivenumber)) || return

    for ((controllerid=0; controllerid < controllercount; controllerid++)); do
        pcipath="$(returnHBAPCIInfo "$controllerid")"
        #### BUG: -LdPdInfo shows all PD on the adapter, not just for given LD..
        #### while arrayid <= arraynumber:

        mapfile -t arraydisk < <(returnUnconfDiskInfo "$controllerid")
    
        for ((i = 0; i < "${#arraydisk[@]}"; i+=UNCONF_DISKINFO_FIELD_COUNT)); do
            array=("${arraydisk[@]:i:UNCONF_DISKINFO_FIELD_COUNT}")
            dbgprint "Unconfed $NAGIOS_GOOD_DISK/$NAGIOS_BAD_DISK Disk c${controllerid}uXpY status : ${array[3]}"
            case "${array[3]}" in
                Online | "Unconfigured(good), Spun Up" | "Unconfigured(good), Spun down" | \
                JBOD | "Hotspare, Spun Up" | "Hotspare, Spun down" | "Online, Spun Up")
                    ((NAGIOS_GOOD_DISK++))
                    # JBOD disks has a real device path and are not masked. Try to find a device name here, if possible.
                    if [ "${array[3]}" = "JBOD" ] && [ "$pcipath" ]; then
                        array[9]="$(findRealDiskDeviceByPath "$pcipath" "${array[9]}" 1)"
                    fi
                    ;;
                *)
                    ((NAGIOS_BAD_DISK++));;
            esac
            printdata+=("c${controllerid}uXpY" "${array[@]:0:5}")
            printdata+=("[${array[6]}:${array[7]}]") # Slot ID
            printdata+=("${array[@]:8}")
            ((${#array[1]} > mlen)) && mlen="${#array[1]}"
            ((${#array[3]} > flen)) && flen="${#array[3]}"
        done
    done

    if ((NAGIOS_MODE)); then
        echo "-- Unconfigured Disk information --"
        # Adjust print format with widths computed above
        drvfmt="%-7s | %-4s | %-${mlen}s | %-8s | %-$((flen + 2))s | %-8s | %-4s | %-8s | %-6s | %-8s\n"
        # shellcheck disable=SC2059
        printf "$drvfmt" "${printdata[@]}"
        echo
    fi
}

findRealDiskDeviceByPath() {
    local pcipath="$1"
    local slotid="$2"
    local jobd="$3"
    local diskprefix="/dev/disk/by-path/pci-${pcipath}-scsi-0:"
    local diskpath searchindex realpath

    dbgprint "Will look for DISKprefix : $diskprefix"
    # RAID disks are usually with a channel of '2', JBOD disks with a channel of '0'
    if [ "$jobd" ]; then
        searchindex=(0)
    else
        searchindex=({1..8})
    fi
    for i in "${searchindex[@]}"; do
        diskpath="$diskprefix${i}:${slotid}:0"
        dbgprint "Looking for DISKpath : $diskpath"
        if [ -e "$diskpath" ]; then
            realpath="$(realpath "$diskpath")"
            dbgprint "Found DISK match: $diskpath -> $realpath"
            echo "$realpath"
            return
        fi
    done
    dbgprint "DISK NOT present: $diskpath"
    echo "N/A"
    return 1
}

printControllers() {
    local controllercount="$1"
    local controllerid hba hbafmt
    local printdata=("-- ID" "H/W Model" "RAM" "Temp" "BBU" "Firmware")
    local mlen=9 #  length of "H/W Model"

    ((PRINT_CONTROLLER)) || return
    ((NAGIOS_MODE)) && return

    echo "-- Controller information --"

    # Collect all HBA info and compute the max length of the model name
    for ((controllerid=0; controllerid < controllercount; controllerid++)); do
        mapfile -t hba < <(returnHBAInfo $controllerid)
        ((${#hba[1]} > mlen)) && mlen="${#hba[1]}"
        printdata+=("${hba[@]}")
    done

    hbafmt="%-5s | %-${mlen}s | %-6s | %-4s | %-6s | %-12s \n"
    # shellcheck disable=SC2059
    printf "$hbafmt" "${printdata[@]}"
    echo
}

max() {
    (( $1 > $2 )) && echo "$1" || echo "$2"
}

main() {
    local controllercount result
    CACHEDIR="$(mktemp -d)"
    trap 'rm -rf "$CACHEDIR"' EXIT

    controllercount="$(countControllers)"

    if ((controllercount == 0)); then
        echo "No MegaRAID or PERC adapter detected on your system!"
        exit 1
    fi

    # List available controllers, arrays and disks
    printControllers "$controllercount"
    processArrays "$controllercount"
    processDisks "$controllercount"
    processUnconfDisks "$controllercount"
    
    if ((DEBUG_MODE)); then
        dbgprint "Printing command cache"
        dbgShowCmdCache
        # Valid code???
        # dbgprint "Printing arraydisk[]"
        # for myd in "${arraydisk[@]}"; do
        #     dbgprint "$myd"
        # done
        dbgShowDiskTableCache CONF_DISKS
        dbgShowDiskTableCache NAGIOS_GOOD_DISKS
        dbgShowDiskTableCache NAGIOS_BAD_DISKS
    fi

    result="Arrays: OK:$NAGIOS_GOOD_ARRAY Bad:$NAGIOS_BAD_ARRAY - Disks: OK:$NAGIOS_GOOD_DISK Bad:$NAGIOS_BAD_DISK"
    if ((NAGIOS_BAD_ARRAY + NAGIOS_BAD_DISK)); then
        if ((NAGIOS_MODE)); then
            echo "RAID ERROR - $result"
            exit 2
        else
            # DO NOT MODIFY OUTPUT BELOW
            # Scripts may relies on it
            # https://github.com/eLvErDe/hwraid/issues/99
            echo $'\n'"There is at least one disk/array in a NOT OPTIMAL state."
            echo "RAID ERROR - $result"
            exit 1
        fi
    elif ((NAGIOS_MODE)); then
        echo "RAID OK - $result"
    fi
    exit 0
}

usage() {
    exitcode="${1:-0}"
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --help, -h  show this help message and exit"
    echo "  --nagios    enable nagios support"
    echo "  --debug     enable debugging output"
    echo "  --notemp    disable temperature reporting"
    exit "$exitcode"
}

# Find MegaCli if specified path is not valid
megapaths="/opt/MegaRAID/MegaCli:/ms/dist/hwmgmt/bin:/opt/MegaRAID/perccli:/opt/MegaRAID/storcli:/opt/lsi/storcli"
for megabin in MegaCli64 MegaCli megacli MegaCli.exe perccli64 perccli storcli64 storcli
do
    dbgprint "Looking for $megabin in PATH $PATH:$megapaths..."
    MEGA_CLI_PATH=$(PATH="$PATH:$megapaths"; command -v $megabin)
    if [ "$MEGA_CLI_PATH" ]; then
        dbgprint "Will use this executable: $MEGA_CLI_PATH"
        break
    fi
done

# Check binary exists (and +x), if not print an error message
# Note that the case in original code where the binary is found but unexecutable is omitted here as it would never happen
if [ -z "$MEGA_CLI_PATH" ]; then
    echo 'Cannot find "MegaCli{64,}", "megacli{64,}", "perccli{64,}" or "storcli{64,}" in your PATH. Please install one of them.'
    exit 3
fi

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # deal with command line options
    OPTS="help,nagios,debug,notemp"
    if ! PARSED=$(getopt --options 'h' --longoptions $OPTS --name "$0" -- "$@"); then
        usage 64
    fi
    eval set -- "$PARSED"
    while true; do
        opt="$1"; shift
        case "$opt" in
            --nagios) NAGIOS_MODE=1;;
            --debug)  DEBUG_MODE=1;;
            --notemp) NO_TEMP_MODE=1;;
            -h | --help) usage;;
            --) break;;
            *)
                echo "Internal error! [$opt]"
                exit 1
                ;;
        esac
    done

  # We need root access to query
  # check for root
    if [ "$(id -u)" -ne 0 ]; then
        echo "# This script requires Administrator privileges"
        exit 5
    fi
    main "$@"
fi