demosite
========

http://sp.netkom-line.de/rrd

setup
=====

a simple cronjob:

    * * * * * /home/user/traffic-rrd-simple-exact.sh cron

or an easy cronjob:

    * * * * * /home/user/traffic-rrd-simple-exact.sh cron --dev eth4 --wwwdir /var/www/html


main loop explained
===================

...
