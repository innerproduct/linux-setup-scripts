#!/bin/bash

# Usage: temp_throttle.sh max_temp
# USE CELSIUS TEMPERATURES.
# version 2.21

cat << EOF
Author: Sepero 2016 (sepero 111 @ gmx . com)
URL: http://github.com/Sepero/temp-throttle/

modified by AT to incorporate CPU idle percentage into throttling logic

EOF

# Additional Links
# http://seperohacker.blogspot.com/2012/10/linux-keep-your-cpu-cool-with-frequency.html

# Additional Credits
# Wolfgang Ocker <weo AT weo1 DOT de> - Patch for unspecified cpu frequencies.

# License: GNU GPL 2.0

# Generic  function for printing an error and exiting.
err_exit () {
	echo ""
	echo "Error: $@" 1>&2
	exit 128
}

if [ $# -ne 2 ]; then
	# If temperature and idle-percentage wasn't given, then print a message and exit.
	echo "Please supply a maximum desired temperature in Celsius and a target CPU idle percentage." 1>&2
	echo "For example:  ${0} 50 80" 1>&2
	exit 2
else
	#Set the first argument as the maximum desired temperature.
	MAX_TEMP=$1
	IDLE_TARGET=$2
	IDLEPC=$2 # just an initial value in case the random check below fails to run
fi


### START Initialize Global variables.

# The frequency will increase when low temperature is reached.
# And when the busiest CPU is less idle than target
LOW_TEMP=$((MAX_TEMP - 5))
LOW_IDLE=$((IDLE_TARGET - 10))
CORES=$(nproc) # Get number of CPU cores.
echo -e "Number of CPU cores detected: $CORES\n"
CORES=$((CORES - 1)) # Subtract 1 from $CORES for easier counting later.
# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Temperatures internally are calculated to the thousandth.
MAX_TEMP=${MAX_TEMP}000
LOW_TEMP=${LOW_TEMP}000

FREQ_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies"
FREQ_MIN="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq"
FREQ_MAX="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"

# Store available cpu frequencies in a space separated string FREQ_LIST.
if [ -f $FREQ_FILE ]; then
	# If $FREQ_FILE exists, get frequencies from it.
	FREQ_LIST=$(cat $FREQ_FILE | xargs -n1 | sort -g -r | xargs) || err_exit "Could not read available cpu frequencies from file $FREQ_FILE"
elif [ -f $FREQ_MIN -a -f $FREQ_MAX ]; then
	# Else if $FREQ_MIN and $FREQ_MAX exist, generate a list of frequencies between them.
	FREQ_LIST=$(seq $(cat $FREQ_MAX) -100000 $(cat $FREQ_MIN)) || err_exit "Could not compute available cpu frequencies"
else
	err_exit "Could not determine available cpu frequencies"
fi

FREQ_LIST_LEN=$(echo $FREQ_LIST | wc -w)

# CURRENT_FREQ will save the index of the currently used frequency in FREQ_LIST.
CURRENT_FREQ=2

# This is a list of possible locations to read the current system temperature.
TEMPERATURE_FILES="
/sys/class/thermal/thermal_zone0/temp
/sys/class/thermal/thermal_zone1/temp
/sys/class/thermal/thermal_zone2/temp
/sys/class/hwmon/hwmon0/temp1_input
/sys/class/hwmon/hwmon1/temp1_input
/sys/class/hwmon/hwmon2/temp1_input
/sys/class/hwmon/hwmon0/device/temp1_input
/sys/class/hwmon/hwmon1/device/temp1_input
/sys/class/hwmon/hwmon2/device/temp1_input
null
"

# Store the first temperature location that exists in the variable TEMP_FILE.
# The location stored in $TEMP_FILE will be used for temperature readings.
for file in $TEMPERATURE_FILES; do
	TEMP_FILE=$file
	[ -f $TEMP_FILE ] && break
done

[ $TEMP_FILE == "null" ] && err_exit "The location for temperature reading was not found."


### END Initialize Global variables.


### START define script functions.

# Set the maximum frequency for all cpu cores.
set_freq () {
	# From the string FREQ_LIST, we choose the item at index CURRENT_FREQ.
	FREQ_TO_SET=$(echo $FREQ_LIST | cut -d " " -f $CURRENT_FREQ)
	echo $FREQ_TO_SET
	for i in $(seq 0 $CORES); do
		# Try to set core frequency by writing to /sys/devices.
		{ echo $FREQ_TO_SET 2> /dev/null > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_max_freq; } ||
		# Else, try to set core frequency using command cpufreq-set.
		{ cpufreq-set -c $i --max $FREQ_TO_SET > /dev/null; } ||
		# Else, return error message.
		{ err_exit "Failed to set frequency CPU core$i. Run script as Root user. Some systems may require to install the package cpufrequtils."; }
	done
}

# Will reduce the frequency of cpus if possible.
throttle () {
	if [ $CURRENT_FREQ -lt $FREQ_LIST_LEN ]; then
		CURRENT_FREQ=$((CURRENT_FREQ + 1))
		echo -n "throttle "
		set_freq $CURRENT_FREQ
	fi
}

# Will increase the frequency of cpus if possible.
unthrottle () {
	if [ $CURRENT_FREQ -ne 1 ]; then
		CURRENT_FREQ=$((CURRENT_FREQ - 1))
		echo -n "unthrottle "
		set_freq $CURRENT_FREQ
	fi
}

get_temp () {
	# Get the system temperature. Take the max of all counters
	
	TEMP=$(cat $TEMPERATURE_FILES 2>/dev/null | xargs -n1 | sort -g -r | head -1)
}

get_idle () {
	# Get the smallest idle percentage among all CPU cores
	#IDLEPC=$(mpstat -P ALL --dec=0 5 1 | grep all|awk '{print $NF}'|grep [0-9+]|sort -g|head -1)
	
	# Get the average idle percentage of all  CPU cores
	IDLEPC=$(mpstat -P ALL --dec=0 5 1 | grep all|awk '{print $NF}'|head -1)
}
### END define script functions.

echo "Initialize to max CPU frequency"
unthrottle


# Main loop
while true; do
	get_temp # Gets the current temperature and set it to the variable TEMP.
	# check how idle the CPU cores are, once in a while
	if   [ $(($RANDOM % 5 == 0)) ]; then
		get_idle # Gets the current idleness of CPUs and sets it to the variable IDLEPC
	fi
	if   [ $TEMP -gt $MAX_TEMP ]; then # Throttle if too hot.
		echo -e "\t temp: ${RED}$TEMP${NC} , idle: $IDLEPC" 
		throttle
		throttle # a bit more aggressive when throttling because of temperature
	elif [ $IDLEPC -gt $IDLE_TARGET ]; then # Throttle if too idle
		echo -e "\t temp: $TEMP , idle: ${RED}$IDLEPC${NC}" 
		throttle
	elif [ $TEMP -le $LOW_TEMP -a $IDLEPC -le $LOW_IDLE ]; then # Unthrottle if cool and not so idle
		echo -e "\t temp: ${GREEN}$TEMP${NC} , idle: ${GREEN}$IDLEPC${NC}" 
		unthrottle
	else
		echo -e "\t temp: $TEMP , idle: $IDLEPC"
		echo "nothing to do"
	fi
	sleep 2 # The amount of time between checking temperatures and idleness.
done

