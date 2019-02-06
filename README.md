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

* we measure in short intervals, usually exactly 1 second.
* we keep the MAX of RX and TX bits and plot it every minute.
* we use the kernel-counters in /sys for bytes of a device.
* we read kernel-uptime after each loop, so we can later normalize to 1 sec.
* we mostly use 'shell built-ins', so these commands are very fast.
* we plot the data in another thread, so measuring is not affected.

Pseudocode:
```
loop_forever
(
	exists_file 'write_data'  =>  write_to_file(RX_MAX, uptime1, uptime1_old)

	uptime1_old = uptime1
	uptime1     = read_uptime_from_kernel()

	RX_bytes_old = RX_bytes
	RX_bytes     = read_RX_bytes_from_kernel()

        DIFF = RX_bytes - RX_bytes_old
	DIFF > RX_MAX  =>  RX_MAX = DIFF

	sleep 1
)

plot_data (called from cron each minute)
(
	touch_file 'write_data'
	wait_till_file_gets_updated (max-data)

	read_file
	update_rrd
	plot_graph_from_rrd
)
```
