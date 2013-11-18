#!/bin/sh -xe

LC_COLLATE=hr_HR.utf8 KOHA_CONF=/etc/koha/sites/ffzg/koha-conf.xml ./html.pl 2>&1 | tee /tmp/koha-bibliografija.log

