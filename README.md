demosite
========

http://sp.netkom-line.de/rrd

setup
=====

a simple cronjob:

    * * * * * /path/to/traffic-rrd-simple-exact.sh cron

or an easy cronjob:

    * * * * * /path/to/traffic-rrd-simple-exact.sh cron --dev eth4 --wwwdir /var/www/html


main loop explained
===================

We measure in short intervals, usually exactly each second.
We keep the max of RX and TX bits and plot it every minute.
We use the kernel-counters in /sys for bytes of a device.

Pseudocode:
```
loop_forever
(
	exists_file 'write_data'  =>  write_to_file(RX_MAX, RX_MAX, uptime1, uptime1_old, uptime2, uptime2_old)

	uptime1_old = uptime1
	uptime1     = read_uptime_from_kernel()

	RX_bytes_old = RX_bytes
	RX_bytes     = read_RX_bytes_from_kernel()

        DIFF = RX_bytes - RX_bytes_old
	DIFF > RX_MAX  =>  RX_MAX = DIFF

	uptime2_old = uptime2
	uptime2     = read_uptime_from_kernel()

	TX_bytes_old = TX_bytes
	TX_bytes     = read_TX_bytes_from_kernel()

        DIFF = TX_bytes - TX_bytes_old
	DIFF > TX_MAX  =>  TX_MAX = DIFF

	sleep 1
)
```
