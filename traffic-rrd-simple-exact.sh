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

# TODO: mainloop_simple() only collect all values with all timestamps in a LIST, in 2nd thread: calc+plot+calc average plateau)
# TODO: autorefresh (depended from plot interval)
# TODO: check_setup|start|restart
# TODO: always do autobackup/autorestore (in/from wwwdir)
# TODO: when having multiple graphs, make it selectable
# TODO: +/- for bigger/smaller picture
# TODO: autoremove lockdir when script ends (trap)
# TODO: --limit_markerfile --limit_mbit=950 (set markerfile/log: unixtime mbit)
# TODO: --logo file.png
# TODO: filename-building-definitions in one place

show_usage()
{
	local mydir="$( cd -P -- "$(dirname -- "$(command -v -- "$0")")" && pwd -P )"
	local script="$( basename "$0" )"

	echo "Usage: $0 <action> --switch1 word1 --switch2 word2"
	echo
	echo " action can be one of:"
	echo " cron|stop|purge|plot|html|status|check_setup|update"
	echo
	echo " switch can be multiple of:"
	echo " --wwwdir|--tmpdir|--dev|--no-autoupdate|--logo"
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

	export HOSTNAME="$( cat '/proc/sys/kernel/hostname' )"
	export LOCKDIR="$TMPDIR/rrd_database_device_${DEV}.lock"
}

log()
{
	local message="$1"
	local prio="$2"

	case "$prio" in
		alert)
			printf '%s\n' "$(date) - $0: $message" >>"$LOG"
		;;
	esac

	test -e /dev/log && logger -s -- "$0: $message"
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
	local word dev parse_next=

	if [ -f '/proc/net/route' ]; then
		# Iface   Destination     Gateway         Flags   RefCnt  Use     Metric  Mask            MTU     Window  IRTT
		# eth0    00000000        0101FEA9        0003    0       0       0       00000000        0       0       0
		# eth0    0101FEA9        00000000        0005    0       0       0       FFFFFFFF        0       0       0

		while read -r dev word _; do {
			case "$word" in
				'00000000')
					printf '%s\n' "$dev"
					return 0
				;;
			esac
		} done </proc/net/route
	else
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
	fi

	false
}

duration_list()
{
	echo '1h 6h 24h 1week 1month 1year'
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

		# symlink default view
		[ -h "$WWWDIR/index.html" ] || ln -s "$WWWDIR/rrd-$DEV-24h.html" "$WWWDIR/index.html"

		return 0
	}

	show_links()
	{
		for obj in $( duration_list ); do {
			[ -n "$firstrun" ] || printf '%s' ' | '
			firstrun=

			if [ "$duration" = "$obj" ]; then
				printf '%s\n' "<b>$obj</b>"
			else
				printf '%s\n' "<a href='rrd-$DEV-$obj.html'>$obj</a>"
			fi
		} done
	}

	cat >"$WWWDIR/rrd-$DEV-$duration.html" <<EOF
<!DOCTYPE html><html lang=en><head><style>
.fcon { position: relative; display: inline-block; }
.flab { position: absolute; bottom: 10px; left: 140px; color: black; }
.gith { position: absolute; bottom: 10px; right: 20px; color: black; }
</style><meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta http-equiv=refresh content=90>
<title>RRD</title></head><body><div class=fcon>
<img src='rrd-$DEV-$duration.png' alt='Traffic RRD-Graph of last $duration' width=$x height=$y>
<span class=flab>Interval: $( show_links )</span><span class=gith>
<a href='http://github.com/bittorf/traffic-rrd-simple-exact'>http://github.com/bittorf/traffic-rrd-simple-exact</a>
</span></div></body></html>
EOF
}

rrd_update()
{
	local rx="$1"
	local tx="$2"

	rrdtool update "$RRD" "N:$rx:$tx" || {
		keep=$(( 60 * 24 * KEEP_DAYS ))

		rrdtool create "$RRD" \
			DS:RX:GAUGE:90:0:U \
			DS:TX:GAUGE:90:0:U \
				--step 60s \
				RRA:MAX:0.5:1:$keep && \
					log "[OK] initial RRD: $RRD" alert
		# now try again
		rrdtool update "$RRD" "N:$rx:$tx"
	}
}

rrd_plot()
{
	local duration="$1"		# 1h,6h,24h,1week,1month,1year
	local file="$2"
	local color_blue='#0000ff'
	local color_red='#00ff00'
	local title

	title="traffic last $duration @ $HOSTNAME on $DEVTYPE-dev '$DEV' |"
	title="$title $( get_dev_speed )mbit/s | MTU: $( get_dev_mtu ) |"
	title="$title driver: $( get_dev_driver ) |"
	title="$title measured each sec from $( basename "$0" )"

	# first valid unixtimestamp:
	# rrdtool fetch "$RRD" MAX | grep -m1 ': [0-9]' | cut -d':' -f1

	rrdtool graph "$file" >/dev/null \
		--start "-$duration" \
		--imgformat PNG --width 1600 --height 800 \
		--vertical-label "bits / second" \
		--title "$title" \
			"DEF:rx=$RRD:RX:MAX" \
			"DEF:tx=$RRD:TX:MAX" \
			"LINE1:rx${color_blue}:RX/download\n" \
			"LINE1:tx${color_red}:TX/upload"
}

test_exists()
{
	local dir_or_file="$1"	# e.g. dir
	local object="$2"	# e.g. /tmp
	local name="$3"		# e.g. ramdisk

	if   [ "$dir_or_file" = 'file' -a -f "$object" ]; then
		log "[OK] $name -> $dir_or_file '$object' exists" 
	elif [ "$dir_or_file" = 'dir' -a -d "$object" ]; then
		log "[OK] $name -> $dir_or_file '$object' exists" 
	else
		log "$name -> does NOT exist: $dir_or_file '$object'"
	fi
}

fetch_max_and_plot_rrd_NEW()
{
	TIME="$( filetime "$MAX" )"
	touch "$MAX.write_now"

	while [ "$( filetime "$MAX" )" = "$TIME" ]; do {
		# wait till MAX gets updated
		sleep 1
	} done

	read -r LIST <"$MAX.write_now"
	rm "$MAX.write_now"

	for TRIPLE in $LIST; do {
		# rx,tx,uptime
		:
	} done



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
		FILE="$WWWDIR/rrd-$DEV-$DURATION.png"

		case "$DURATION" in
			1h) MIN_AGE=60 ;;
			6h) MIN_AGE=180 ;;
			24h) MIN_AGE=600 ;;
			1week) MIN_AGE=3600 ;;
			1month) MIN_AGE=$(( 3600 * 6 )) ;;
			1year) MIN_AGE=$(( 3600 * 12 )) ;;
			*) MIN_AGE=60 ;;
		esac

		[ "$( fileage_in_sec "$FILE" )" -gt $MIN_AGE ] && {
			rrd_plot "$DURATION" "$FILE"

			[ "$DURATION" = '1year' ] && {
				[ "$AUTOUPDATE" = 'true' ] && {
					try_update && {
						# if there is an update and install was fine:
						stop_mainloop
						# ...and cron will reinit
					}
				}
			}
		}
	} done
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
		FILE="$WWWDIR/rrd-$DEV-$DURATION.png"

		case "$DURATION" in
			1h) MIN_AGE=60 ;;
			6h) MIN_AGE=180 ;;
			24h) MIN_AGE=600 ;;
			1week) MIN_AGE=3600 ;;
			1month) MIN_AGE=$(( 3600 * 6 )) ;;
			1year) MIN_AGE=$(( 3600 * 12 )) ;;
			*) MIN_AGE=60 ;;
		esac

		[ "$( fileage_in_sec "$FILE" )" -gt $MIN_AGE ] && {
			rrd_plot "$DURATION" "$FILE"

			[ "$DURATION" = '1year' ] && {
				[ "$AUTOUPDATE" = 'true' ] && {
					try_update && {
						# if there is an update and install was fine:
						stop_mainloop
						# ...and cron will reinit
					}
				}
			}
		}
	} done
}

try_update()
{
	local name='traffic-rrd-simple-exact.sh'
	local url="http://intercity-vpn.de/$name"
	local file="$TMPDIR/$name"

	wget -qO "$file" "$url" >/dev/null 2>/dev/null || log "[ERR] download failed: $url"

	if tail -n1 "$file" | grep -q ^'# END'$ ; then
		if cmp -s "$file" "$0"; then
			:
#			log "[OK] no new version"
		else
			if sh -n "$file"; then
				log "[OK] installing new version" alert
				mv "$file" "$0" && chmod +x "$0"
				html_generate

				return 0
			else
				log "[ERR] download broken"
			fi
		fi
	else
		log "[ERR] download invalid"
	fi

	rm "$file"
	false
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
	date +%s -r "$1" 2>/dev/null || echo '0'
}

fileage_in_sec()
{
	local file="$1"
	local unix_now="$( date +%s )"
	local unix_file="$( filetime "$file" )"

	echo $(( unix_now - unix_file ))
}

stop_mainloop()
{
	if [ -f "$LOCKDIR/pid" ]; then
		read -r PID <"$LOCKDIR/pid"
		log "stopping PID $PID from $LOCKDIR"
		kill "$PID"

		log "removing lockdir '$LOCKDIR', pid $PID was killed" alert
		rm -fR "$LOCKDIR"
	else
		log "no pidfile found"
		false
	fi
}

measure_and_loop_foreverNEW()
{
	# cache command
	sleep 0

	# first read for avoiding a large step
	read -r RX <"/sys/class/net/$DEV/statistics/rx_bytes"
	read -r TX <"/sys/class/net/$DEV/statistics/tx_bytes"
	sleep 1

	while true; do {
		# check for file with shell-builtin commando
		read 2>/dev/null NOP -r "$MAX.write_now" && {
			printf '%s\n' "$LIST" >"$MAX"
			LIST=
		}

		OLD_RX=$RX
		read -r RX <"/sys/class/net/$DEV/statistics/rx_bytes"
		DIFF_RX=$(( RX - OLD_RX ))

		OLD_TX=$TX
		read -r TX <"/sys/class/net/$DEV/statistics/tx_bytes"
		DIFF_TX=$(( TX - OLD_TX ))

		read -r UPTIME </proc/uptime
		TRIPLE="$DIFF_RX,$DIFF_TX,$UPTIME"
		LIST="$LIST $TRIPLE"

		sleep 1
	} done
}

measure_and_loop_forever()
{
	RX_MAX=0
	TX_MAX=0

	while true; do {
		[ -f "$MAX.write_now" ] && {
			ALL="RX_MAX=$RX_MAX; TX_MAX=$TX_MAX; T1=$T1; OLD_T1=$OLD_T1; T2=$T2; OLD_T2=$OLD_T2; LIST_RX='$LIST_RX'; LIST_TX='$LIST_TX'"
			RX_MAX=0; LIST_RX=
			TX_MAX=0; LIST_TX=

			printf '%s\n' "$ALL" >"$MAX"
		}

		OLD_T1=$T1
		read -r T1 _ </proc/uptime

		OLD_RX=$RX
		read -r RX <"/sys/class/net/$DEV/statistics/rx_bytes"

		DIFF_RX=$(( RX - ${OLD_RX:-$RX} ))
		[ $DIFF_RX -gt $RX_MAX ] && RX_MAX=$DIFF_RX
		LIST_RX="$LIST_RX $DIFF_RX"


		OLD_T2=$T2
		read -r T2 _ </proc/uptime

		OLD_TX=$TX
		read -r TX <"/sys/class/net/$DEV/statistics/tx_bytes"

		DIFF_TX=$(( TX - ${OLD_TX:-$TX} ))
		[ $DIFF_TX -gt $TX_MAX ] && TX_MAX=$DIFF_TX		# TODO: store T2/OLD_T2 from this MAX
		LIST_TX="$LIST_TX $DIFF_TX"

		sleep 1
	} done
}

# defaults:
[ -z "$WWWDIR" ] && WWWDIR='/var/www/html'
[ -z "$TMPDIR" ] && TMPDIR='/dev/shm'
[ -z "$DEV" ] && DEV="$( get_dev_from_ip_default_route )"
[ -z "$AUTOUPDATE" ] && AUTOUPDATE='true'

build_vars

case "$ACTION" in
	'update')
		try_update
	;;
	'cron')
		if mkdir "$LOCKDIR" 2>/dev/null; then
			log "first call for collecting $DEV - pid $$" alert
			echo "$$" >"$LOCKDIR/pid"
			html_generate
			measure_and_loop_forever
		else
			fetch_max_and_plot_rrd
		fi
	;;
	'status')
		test_exists 'dir'  "$LOCKDIR" 'lockdir'
		test_exists 'file' "$RRD" 'rrd-database'
		test_exists 'file' "$MAX" 'last-min-max-values'
		test_exists 'file' "$LOG" 'logfile'
	;;
	'stop')
		stop_mainloop
	;;
	'plot')
		for DURATION in $( duration_list ); do {
			rrd_plot "$DURATION" "$WWWDIR/rrd-$DEV-$DURATION.png"
		} done

		log "RRD: $RRD"
	;;
	'html')
		html_generate
	;;
	*)
		show_usage
		false
	;;
esac

# END
