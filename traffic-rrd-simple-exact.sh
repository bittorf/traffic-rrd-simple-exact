#!/bin/sh

ACTION="$1"

while [ -n "$1" ]; do {
	case "$1" in
		'--wwwdir')
			test -d "$2" && WWWDIR="$2"
			shift
		;;
		'--tmpdir')
			test -d "$2" && TMPDIR="$2"
			shift
		;;
		'--dev')
			DEV="$2"
			shift
		;;
		'--no-autoupdate')
			AUTOUPDATE='false'
		;;
	esac

	shift
} done

# defaults:
[ -z "$WWWDIR" ] && WWWDIR='/var/www/html'
[ -z "$TMPDIR" ] && TMPDIR='/dev/shm'
[ -z "$DEV" ] && DEV="$( get_dev_from_ip_default_route )"
[ -z "$AUTOUPDATE" ] && AUTOUPDATE='true'

# TODO: start|restart|backup|autorestore
# TODO: autoupdate-mode
# TODO: autoremove lockdir when script ends (trap)
# TODO: read integers from MAX-file, so tmpfs can have 'noexec'
# TODO: --limit_markerfile --limit_mbit=950 (set markerfile/log: unixtime mbit)
# TODO: setup-test mode
# TODO: add logo

show_usage()
{
	local mydir="$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"
	local script="$( basename "$0" )"

	echo "Usage: $0 <action> --switch1 word1 --switch2 word2"
	echo
	echo " e.g.: $0 stop"
	echo " e.g.: $0 plot --dev eth4"
	echo " e.g.: $0 plot --dev eth4 --wwwdir /var/www"
	echo
	echo " or a cronjob which does everything automatically:"
	echo " * * * * * $mydir/$script cron --wwwdir /var/www/html"
	echo
}

build_vars()
{
	export DEV="$DEV"
	export DEVSHORT="${DEV%.*}"	# eth0.1 -> eth0
	export DEVTYPE='wired'
	export DEVSPEED='auto'		# see get_dev_speed()

	export TMPDIR='/dev/shm'	# should be a (fast) tmpfs
	export WWWDIR="$WWWDIR/rrd"	# must be writeable for user
	export KEEP_DAYS=365		# size rrd-database

	export LOG="$TMPDIR/rrd_database_device_${DEV}.log"
	export RRD="$TMPDIR/rrd_database_device_${DEV}.rrd"
	export MAX="$TMPDIR/rrd_database_device_${DEV}.lastmax"

	export HOSTNAME="$( cat '/proc/sys/kernel/hostname' 2>/dev/null || sysctl -n kern.hostname )"
	export LOCKDIR="$TMPDIR/rrd_database_device_${DEV}.lock"
}

log()
{
	case "$2" in
		alert)
			printf '%s\n' "$(date) - $0: $1" >>"$LOG"
		;;
	esac

	logger -s -- "$0: $1"
}

get_dev_speed()		# only for legend in RRD-plot in [mbit/s]
{
	if [ -f "/sys/class/net/$DEVSHORT/speed" ]; then
		cat "/sys/class/net/$DEVSHORT/speed"
	else
		echo '???'
	fi
}

get_dev_mtu()
{
	cat "/sys/class/net/$DEVSHORT/mtu"
}

get_dev_driver()
{
	basename "$( readlink "/sys/class/net/$DEVSHORT/device/driver" )"
}

get_dev_from_ip_default_route()
{
	local word parse_next=

	# e.g. default via 10.63.22.97 dev eth0
	# e.g. default via 10.63.21.97 dev eth0.1 metric 2 onlink

	for word in $( ip route list exact '0.0.0.0/0' ); do {
		case "$parse_next" in
			'true')
				printf '%s\n' "$word"
				return 0
			;;
		esac

		case "$word" in
			'dev')
				parse_next='true'
			;;
		esac
	} done

	false
}

duration_list()
{
	echo '1h 24h 1week 1month 1year'
}

html_generate()
{
	local duration="$1"
	local x=1400
	local y=770
	local obj firstrun=true

	[ -z "$duration" ] && {
		for duration in $( duration_list ); do {
			html_generate "$duration"
		} done

		[ -h "$WWWDIR/index.html" ] || ln -s "$WWWDIR/rrd-24h.html" "$WWWDIR/index.html"
		return 0
	}

	show_links()
	{
		for obj in $( duration_list ); do {
			[ -n "$firstrun" ] || printf '%s' ' | '
			firstrun=

			if [ "$duration" = "$obj" ]; then
				printf '%s\n' "<b>$obj</a>"
			else
				printf '%s\n' "<a href='rrd-$obj.html'>$obj</a>"
			fi
		} done
	}

# <span class=flab>Interval: <a href='rrd-1h.html'>1h</a> | <b>24h</b> | <a href='rrd-1week.html'>1week</a> | <a href='rrd-1month.html'>1month</a> | <a href='rrd-1year.html'>1year</a></span>

	cat >"$WWWDIR/rrd-$duration.html" <<EOF
<!DOCTYPE html><html lang=en><head><style>
.fcon { position: relative; display: inline-block; }
.flab { position: absolute; bottom: 10px; left: 140px; color: black; }
.gith { position: absolute; bottom: 10px; right: 20px; color: black; }
</style><meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>RRD</title></head><body><div class=fcon>
<img src='rrd-$duration.png' alt='Traffic RRD-Graph of last $duration' width=$x height=$y>
<span class=flab>Interval: $( show_links )</span><span class=gith>
<a href='http://github.com/bittorf/traffic-rrd-simple-exact'>http://github.com/bittorf/traffic-rrd-simple-exact</a>
</span></div></body></html>
EOF
}

rrd_update()
{
	local rx="$1"
	local tx="$2"
	local keep tenge

	rrdtool update "$RRD" "N:$rx:$tx" || {
		keep=$(( 60 * 24 * KEEP_DAYS ))

		rrdtool create "$RRD" \
			DS:RX:GAUGE:90:0:U \
			DS:TX:GAUGE:90:0:U \
				--step 60s \
				RRA:LAST:0.5:1:$keep && \
					log "[OK] init RRD: $RRD"
		# now try again
		rrdtool update "$RRD" "N:$rx:$tx"
	}
}

rrd_plot()
{
	local duration="$1"		# 1h,24h,1week,1month,1year
	local file="$2"
	local color_blue='#0000ff'
	local color_red='#00ff00'
	local title

	title="traffic @ $HOSTNAME on $DEVTYPE-dev '$DEV' |"
	title="$title $( get_dev_speed )mbit/s | MTU: $( get_dev_mtu ) |"
	title="$title driver: $( get_dev_driver ) |"
	title="$title measured each sec from $( basename "$0" )"

	# first valid unixtimestamp:
	# rrdtool fetch "$RRD" LAST | grep -m1 ': [0-9]' | cut -d':' -f1

	rrdtool graph "$file" >/dev/null \
		--start "-$duration" \
		--imgformat PNG --width 1600 --height 800 \
		--vertical-label "bits / second" \
		--title "$title" \
			"DEF:rx=$RRD:RX:LAST" \
			"DEF:tx=$RRD:TX:LAST" \
			"LINE1:rx${color_blue}:RX/download\n" \
			"LINE1:tx${color_red}:TX/upload"
}

test_exists()
{
	local dir_or_file="$1"	# e.g. dir
	local object="$2"	# e.g. /tmp
	local name="$3"		# e.g. ramdisk
	local parameter

	if   [ "$dir_or_file" = 'file' -a -f "$object" ]; then
		log "[OK] $name -> $dir_or_file '$object' exists" 
	elif [ "$dir_or_file" = 'dir' -a -d "$object" ]; then
		log "[OK] $name -> $dir_or_file '$object' exists" 
	else
		log "$name -> does NOT exist: $dir_or_file '$object'"
	fi
}

fetch_max_and_plot_rrd()
{
	TIME="$( filetime "$MAX" )"
	touch "$MAX.write_now"

	while [ "$( filetime "$MAX" )" = "$TIME" ]; do {
		# wait till MAX gets updated
		sleep 1
	} done
		
	. "$MAX"
	rm "$MAX.write_now"

	T1a="$( uptime_to_centysec "$T1" )"
	T1b="$( uptime_to_centysec "$OLD_T1" )"
	if isnumber "$T1a" && isnumber "$T1b"; then
		T1_DIFF=$(( T1a - T1b ))
	else
		T1_DIFF=100
	fi

	T2a="$( uptime_to_centysec "$T2" )"
	T2b="$( uptime_to_centysec "$OLD_T2" )"
	if isnumber "$T2a" && isnumber "$T2b"; then
		T2_DIFF=$(( T2a - T2b ))
	else
		T2_DIFF=100
	fi

	isnumber "$RX_MAX" || RX_MAX=0
	isnumber "$TX_MAX" || TX_MAX=0

	# convert bytes to bits and normalize to 1 second
	rrd_update \
		"$(( (8 * RX_MAX * 100) / T1_DIFF ))" \
		"$(( (8 * TX_MAX * 100) / T2_DIFF ))"

	for DURATION in $( duration_list ); do {
		FILE="$WWWDIR/rrd-$DURATION.png"

		case "$DURATION" in
			1h) MIN_AGE=60 ;;
			24h) MIN_AGE=60 ;;
			1week) MIN_AGE=3600 ;;
			1month) MIN_AGE=$(( 3600 * 6 )) ;;
			1year) MIN_AGE=$(( 3600 * 12 )); test "$AUTOUPDATE" = 'true' && try_update ;;
			*) MIN_AGE=60 ;;
		esac

		[ "$( fileage_in_sec "$FILE" )" -gt $MIN_AGE ] && {
			rrd_plot "$DURATION" "$FILE"
		}
	} done
}

try_update()
{
	local name='traffic-rrd-simple-exact.sh'
	local url="http://intercity-vpn.de/$name"
	local file="$TMPDIR/$name"

	wget -qO "$file" "$url" >/dev/null 2>/dev/null

	if tail -n1 "$file" | grep -q ^'# END'$ ; then
		mv "$file" "$0" && chmod +x "$0"
		html_generate
	else
		rm "$file"
		return 1
	fi
}

isnumber()
{
	test "${1:-a}" -eq "${1##*[!0-9-]*}" 2>/dev/null
}

uptime_to_centysec()
{
	local uptime="$1"			# e.g. 24.89

	echo "${uptime%.*}${uptime#*.}"		# e.g. 2489
}

filetime()
{
	date +%s -r "$1"
}

fileage_in_sec()
{
	local file="$1"
	local unix_now="$( date +%s )"
	local unix_file="$( filetime "$file" )"

	echo $(( unix_now - unix_file ))
}

build_vars

case "$ACTION" in
	'update')
		try_update
		exit 0
	;;
	'cron')
		if mkdir "$LOCKDIR" 2>/dev/null; then
			log "first call for collecting $DEV - pid $$"
			echo "$$" >"$LOCKDIR/pid"
			html_generate
		else
			fetch_max_and_plot_rrd
			exit 0
		fi
	;;
	'status')
		test_exists 'dir'  "$LOCKDIR" 'lockdir'
		test_exists 'file' "$RRD" 'rrd-database'
		test_exists 'file' "$MAX" 'last-min-max-values'
		test_exists 'file' "$LOG" 'logfile'

		exit 0
	;;
	'stop')
		if [ -f "$LOCKDIR/pid" ]; then
			read -r PID <"$LOCKDIR/pid"
			log "stopping PID $PID"
			kill "$PID"
		else
			log "no pidfile found"
		fi

		if [ -d "$LOCKDIR" ]; then
			log "removing lockdir '$LOCKDIR'"
			rm -fR "$LOCKDIR"
		else
			log "no lockdir found"
		fi

		exit 0
	;;
	'plot')
		for DURATION in $( duration_list ); do {
			rrd_plot "$DURATION" "$WWWDIR/rrd-$DURATION.png"
		} done

		log "RRD: $RRD"
		exit 0
	;;
	'html')
		html_generate
		exit 0
	;;
	'collect')
		log "abort with CTRL+C and plot with: $0 plot"
		log "RRD: $RRD"
	;;
	*)
		show_usage
		exit 1
	;;
esac

RX_MAX=0
TX_MAX=0

while true; do {
	[ -f "$MAX.write_now" ] && {
		printf '%s\n' "RX_MAX=$RX_MAX; TX_MAX=$TX_MAX; T1=$T1; OLD_T1=$OLD_T1; T2=$T2; OLD_T2=$OLD_T2" >"$MAX"
		RX_MAX=0
		TX_MAX=0
	}

	OLD_T1=$T1
	read -r T1 _ </proc/uptime

	OLD_RX=$RX
	read -r RX <"/sys/class/net/$DEV/statistics/rx_bytes"

	DIFF_RX=$(( RX - ${OLD_RX:-$RX} ))
	[ $DIFF_RX -gt $RX_MAX ] && RX_MAX=$DIFF_RX


	OLD_T2=$T2
	read -r T2 _ </proc/uptime

	OLD_TX=$TX
	read -r TX <"/sys/class/net/$DEV/statistics/tx_bytes"

	DIFF_TX=$(( TX - ${OLD_TX:-$TX} ))
	[ $DIFF_TX -gt $TX_MAX ] && TX_MAX=$DIFF_TX

	sleep 1
} done

# END
