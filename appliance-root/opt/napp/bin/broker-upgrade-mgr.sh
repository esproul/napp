#!/bin/bash

############################################################
# Support functions
############################################################

function usage {
cat <<EOU
broker-update-mgr [-h] [-v]

    -h:     This help message
    -v:     Verbose mode

This tool will update the Circonus broker software based on the
maintenance windows set in the circonus-appliance.conf file.
EOU
}

function vlog {
  if [[ "$VERBOSE" -eq "0" ]]; then return 0; fi
  echo $*
}

function set_platform {
    case `uname -v` in
        omnios-*)
            MY_OS="omnios"
            PKGNAME="field/broker"
            PKG=/usr/bin/pkg
            SVCS=/usr/bin/svcs
            SVCADM=/usr/sbin/svcadm
            ;;
        joyent_*)
            MY_OS="smartos"
            PKGNAME="unknown"
            ;;
        *)
            echo "Unkown OS: $MY_OS"
            exit 2
            ;;
    esac
}

function broker_current_version {
    if [[ -n "$CURRENT_BROKER_VERSION" ]]; then
        echo $CURRENT_BROKER_VERSION
        return
    fi
    local VERSION=""
    case "$MY_OS" in
        omnios)
            VERSION=`pkg list -H -v $PKGNAME 2>&1 | cut -d@ -f2 | cut -d, -f1 | sed -e 's/.*\.//' | sed -e 's/[^0-9]//g'`
            ;;
        *)
            VERSION=
            ;;
    esac
    CURRENT_BROKER_VERSION=$VERSION
    echo $VERSION
}

function circonus_url {
    CIRCONUS_URL="http://login.circonus.com"
    if [[ -n "$URLS_RESOLVED" ]]; then
        if [[ -n "$INSIDE_URL" ]]; then
            echo $INSIDE_URL
        else
            echo $CIRCONUS_URL
        fi
        return
    fi
    INSIDE_URL=`$NOITD -x '/noit/circonus//appliance//circonus_url/text()' 2>&1 | awk '/^0:/{print $2;}'`
    URLS_RESOLVED=1
    echo $(circonus_url)
}

function broker_required_version {
    if [[ "$MINVERSION" -ne 0 ]]; then
        echo $MINVERSION
        return
    fi
    URLBASE=$(circonus_url)
    MINVERSION=$(curl -H'Accept: text/plain' -s $URLBASE/api/broker_version 2>&1 | awk '{if(/^[0-9]+$/){print $0;}else{print "0"} exit(0);}')
    if [[ "$MINVERSION" -eq "0" ]]; then MINVERSION=-1; fi
    echo "$MINVERSION"
}

function can_update {
    local TYPE=$1
    if [[ -z "$TYPE" ]]; then TYPE="regular"; fi
    local DOW=$(date +%A)
    local HOD=$(($(date +%H) + 0))
    (echo "0: 0-0" ; # This row matches nothing, in case the awk xpath is blank
     $NOITD -x "/noit/circonus//appliance//auto_upgrade/$TYPE/*[name() = 'Any' or name() = '$DOW']/text()" 2>&1) | \
    sed -e 's/^.*: *//g' | \
    awk -F- "
      BEGIN { rv = 1; }
      {
        if($HOD >= (\$1+0) && $HOD < (\$2+0)) {
          rv = 0;
        }
      }
      END { exit rv; }
    "
    local CAN=$?
    return $CAN
}

function broker_service_state {
    case $1 in
        save)
            vlog "Assessing current broker state."
            case $MY_OS in
                omnios)
                    for svc in $BROKER_SERVICES; do
                        local STATE=$($SVCS -ostate -H $svc)
                        if [[ "$STATE" != "disabled" ]]; then STATE="online"; fi
                        BROKER_STATE[$svc]=$STATE
                        
                    done
                    ;;
                *) echo "Impossible OS: $MY_OS."; exit 2;;
            esac
            SAVED_STATE=1
            ;;
        restore)
            if [[ $SAVED_STATE -ne 1 ]]; then
                echo "Attempted to restore service state without first saving it."
                exit 2
            fi
            case $MY_OS in
                omnios)
                    for svc in $BROKER_SERVICES; do
                        local CURRENT_STATE=$($SVCS -ostate -H $svc)
                        # handle: maintenance -> online
                        # handle: disabled    -> online
                        # handle: !disabled   -> disabled
                        if [[ "$CURRENT_STATE" == "maintenance" && 
                              ${BROKER_STATE[$svc]} == "online" ]]; then
                            vlog "clearing $svc in maintenance"
                            $SVCADM clear $svc
                        elif [[ "$CURRENT_STATE" == "disabled" && 
                              ${BROKER_STATE[$svc]} == "online" ]]; then
                            vlog "enabling $svc"
                            $SVCADM enable $svc
                        elif [[ "$CURRENT_STATE" != "disabled" && 
                              ${BROKER_STATE[$svc]} == "disabled" ]]; then
                            vlog "disabling $svc"
                            $SVCADM disable $svc
                        fi
                    done
                    ;;
                *) echo "Impossible OS: $MY_OS."; exit 2;;
            esac
            vlog "Restoring prior broker state."
            ;;
        *)
            echo "broker_service_state $* : command not recognized."
            exit 2
            ;;
    esac
}

function broker_update {
    case $MY_OS in
        omnios)
            if [[ $VERBOSE -ne 0 ]]; then
                $PKG update broker | cat
            else
                $PKG update broker 2>&1 > /dev/null
            fi
            ;;
        *) echo "Impossible OS: $MY_OS."; exit 2;;
    esac
}

############################################################
# Main Program
############################################################

NOITD=/opt/noit/prod/sbin/noitd
REGULAR_UPDATES=0
SECURITY_UPDATES=0
VERBOSE=0

set -- `getopt hv $*`
if [[ $? != 0 ]]; then
    usage
    exit 2
fi
for i in $*
do
    case $i in
        -h) usage; exit 0;;
        -v) VERBOSE=1
    esac
done


if [[ $(id -u) != "0" ]]; then
    echo "Must be run as root"
    exit 2
fi

MY_OS=
PKGNAME=
set_platform

SAVED_STATE=0
declare -A BROKER_STATE
BROKER_SERVICES="noitd jezebel"
for svc in $BROKER_SERVICES; do
    BROKER_STATE[$svc]="online"
done

# We else if the regular vs. security because if we can do regular
# updates, we'll try to do updates regardless.  In other words,
# we don't need to check special security concerns because we
# will be attempting an update anyway.

if can_update regular ; then
    vlog "regular updates can happen"
elif can_update security ; then
    vlog "security updates can happen"
    if [[ $(broker_current_version) -lt $(broker_required_version) ]]; then
        vlog "Security update required: $(broker_current_version) -> $(broker_required_version)."
    else
        vlog "No security updates required."
        exit 0
    fi
else
    vlog "Outside of any maintenance windows. Doing nothing."
    exit 0
fi

# If we are here, we are going to be attempting updates.

broker_service_state save
broker_update
broker_service_state restore
exit 0
