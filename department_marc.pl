#!/usr/bin/perl

use warnings;
use strict;

use Data::Dump qw(dump);
use autodie;
use Storable;

use lib '/srv/koha_ffzg';
use C4::Context;

my $dbh = C4::Context->dbh;

sub debug {
	my ($title, $data) = @_;
	print "# $title ",dump($data), $/ if $ENV{DEBUG};
}

my $auth_department = retrieve '/dev/shm/auth_department.storable';

my $authors = retrieve '/dev/shm/authors.storable';

my $sth_marc  = $dbh->prepare(q{
select
	marc
from biblioitems
where
	biblionumber = ?
});


foreach ( keys %$auth_department ) {
	next unless m/psiho/;
	my $marc_file = "/dev/shm/$_.mrac";
	warn "# $marc_file\n";

	open(my $marc_fh, '>', $marc_file);

	foreach my $auth ( @{ $auth_department->{$_} } ) {
		foreach my $l1 ( keys %{ $authors->{$auth} } ) {
			foreach my $l2 ( keys %{ $authors->{$auth}->{$l1} } ) {
				foreach my $biblionumber ( @{ $authors->{$auth}->{$l1}->{$l2} } ) {
					$sth_marc->execute($biblionumber);
					my ( $marc ) = $sth_marc->fetchrow_array;
					print $marc_fh $marc;
				}
			}
		}
	}


	close($marc_fh);

}
