#!/bin/sh -e

cd /srv/koha-bibliografija
LC_COLLATE=hr_HR.utf8 KOHA_CONF=/etc/koha/sites/ffzg/koha-conf.xml ./html.pl > /tmp/koha-bibliografija.log

