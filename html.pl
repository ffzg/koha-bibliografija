#!/usr/bin/perl

# LC_COLLATE=hr_HR.utf8 KOHA_CONF=/etc/koha/sites/ffzg/koha-conf.xml ./html.pl

use warnings;
use strict;

use DBI;
use Data::Dump qw(dump);
use autodie;
use locale;

use lib '/srv/koha_ffzg';
use C4::Context;
use XML::LibXML;
use XML::LibXSLT;

my $dbh = C4::Context->dbh;

my $xslfilename = 'compact.xsl';

my $authors;

my $sth_select_authors  = $dbh->prepare(q{
select
	biblionumber,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="9"]') as first_author,
	ExtractValue(marcxml,'//datafield[@tag="700"]/subfield[@code="9"]') as other_authors,
	ExtractValue(marcxml,'//datafield[@tag="942"]/subfield[@code="t"]') as category
from biblioitems where agerestriction > 0
});

$sth_select_authors->execute();
while( my $row = $sth_select_authors->fetchrow_hashref ) {
#	warn dump($row),$/;
	my $all_authors = join(' ', $row->{first_author}, $row->{other_authors});
	foreach my $authid ( split(/\s+/, $all_authors) ) {
		push @{ $authors->{$authid}->{ $row->{category} } }, $row->{biblionumber};
	}
}

my $auth_header;
my @authors;

my $all_authids = join(',', grep { length($_) > 0 } keys %$authors);
my $sth_auth = $dbh->prepare(q{
select
	authid,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="a"]') as full_name
from auth_header
where
	ExtractValue(marcxml,'//datafield[@tag="024"]/subfield[@code="a"]') <> '' and
	authid in (} . $all_authids . q{)
});

$sth_auth->execute();
while( my $row = $sth_auth->fetchrow_hashref ) {
	warn dump( $row );
	$auth_header->{ $row->{authid} } = $row->{full_name};
	push @authors, $row;

}

sub html_title {
	return qq|<html>
<head>
<meta charset="UTF-8">
<title>|, join(" ", @_), qq|</title>
</head>
<body>
|;
}

sub html_end {
	return qq|</body>\n</html\n|;
}


my $sth_marcxml = $dbh->prepare(q{
select marcxml from biblioitems where biblionumber = ?
});

sub biblioitem_html {
	my $biblionumber = shift;

	$sth_marcxml->execute( $biblionumber );
	my $xmlrecord = $sth_marcxml->fetchrow_arrayref->[0];

	my $parser = XML::LibXML->new();
	$parser->recover_silently(0); # don't die when you find &, >, etc
    my $source = $parser->parse_string($xmlrecord);
	my $style_doc = $parser->parse_file($xslfilename);

	my $xslt = XML::LibXSLT->new();
	my $parsed = $xslt->parse_stylesheet($style_doc);
	my $transformed = $parsed->transform($source);
	return $parsed->output_string( $transformed );
}


mkdir 'html' unless -d 'html';

open(my $index, '>:encoding(utf-8)', 'html/index.html');
print $index html_title('Bibliografija Filozogskog fakulteta');

my $first_letter;

foreach my $row ( sort { $a->{full_name} cmp $b->{full_name} } @authors ) {

	my $first = substr( $row->{full_name}, 0, 1 );
	if ( $first ne $first_letter ) {
		print $index qq{</ul>\n} if $first_letter;
		$first_letter = $first;
		print $index qq{<h1>$first</h1>\n<ul>\n};
	}
	print $index qq{<li><a href="}, $row->{authid}, qq{.html">}, $row->{full_name}, "</a></li>\n";

	open(my $fh, '>:encoding(utf-8)', "html/$row->{authid}.html");
	print $fh html_title($row->{full_name}, "bibliografija");
	foreach my $category ( sort keys %{ $authors->{ $row->{authid} } } ) {
		print $fh qq|<h1>$category</h1>\n<ul>\n|;
		foreach my $biblionumber ( @{ $authors->{ $row->{authid} }->{$category} } ) {
			print $fh qq|<li><a href="https://koha.ffzg.hr/cgi-bin/koha/opac-detail.pl?biblionumber=$biblionumber">$biblionumber</a>|, biblioitem_html($biblionumber), qq|</li>\n|;
		}
		print $fh qq|</ul>\n|;
	}
	print $fh html_end;
	close($fh);

}

print $index html_end;

print dump( $authors );

print dump( $auth_header );



