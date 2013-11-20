#!/usr/bin/perl

# LC_COLLATE=hr_HR.utf8 KOHA_CONF=/etc/koha/sites/ffzg/koha-conf.xml ./html.pl

use warnings;
use strict;

use DBI;
use Data::Dump qw(dump);
use autodie;
use locale;
use Text::Unaccent;

use lib '/srv/koha_ffzg';
use C4::Context;
use XML::LibXML;
use XML::LibXSLT;
use XML::Simple;

my $dbh = C4::Context->dbh;

my $xslfilename = 'compact.xsl';

my $authors;
my $marcxml;

my $sth_select_authors  = $dbh->prepare(q{
select
	biblionumber,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="9"]') as first_author,
	ExtractValue(marcxml,'//datafield[@tag="700"]/subfield[@code="9"]') as other_authors,
	ExtractValue(marcxml,'//datafield[@tag="942"]/subfield[@code="t"]') as category,
	itemtype,
	marcxml
from biblioitems
where
	agerestriction > 0
	and SUBSTR(ExtractValue(marcxml,'//controlfield[@tag="008"]'),8,4) between 2008 and 2013
order by SUBSTR(ExtractValue(marcxml,'//controlfield[@tag="008"]'),8,4) desc
});

$sth_select_authors->execute();
while( my $row = $sth_select_authors->fetchrow_hashref ) {
#	warn dump($row),$/;
	if ( $row->{first_author} || $row->{itemtype} !~ m/^KNJ/ ) {
		my $all_authors = join(' ', $row->{first_author}, $row->{other_authors});
		foreach my $authid ( split(/\s+/, $all_authors) ) {
			push @{ $authors->{$authid}->{ $row->{category} } }, $row->{biblionumber};
			$marcxml->{ $row->{biblionumber} } = $row->{marcxml};
		}
	} else {
		my $xml = XMLin( $row->{marcxml}, ForceArray => [ 'subfield' ] );
		foreach my $f700 ( map { $_->{subfield} } grep { $_->{tag} eq 700 } @{ $xml->{datafield} } ) {
			my $authid = 0;
			my $is_edt = 0;
			foreach my $sf ( @$f700 ) {
				if ( $sf->{code} eq '4' && $sf->{content} =~ m/^edt/ ) {
					$is_edt++;
				} elsif ( $sf->{code} eq '9' ) {
					$authid = $sf->{content};
				}
			}
			if ( $authid && $is_edt ) {
#				warn "# ++ ", $row->{biblionumber}, " $authid f700 ", dump( $f700 );
				push @{ $authors->{$authid}->{ $row->{category} } }, $row->{biblionumber};
				$marcxml->{ $row->{biblionumber} } = $row->{marcxml};
			} else {
#				warn "# -- ", $row->{biblionumber}, " f700 ", dump( $f700 );
			}
		}
	}
}

my $auth_header;
my $auth_department;
my @authors;

my $all_authids = join(',', grep { length($_) > 0 } keys %$authors);
my $sth_auth = $dbh->prepare(q{
select
	authid,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="a"]') as full_name,
	ExtractValue(marcxml,'//datafield[@tag="680"]/subfield[@code="a"]') as department
from auth_header
where
	authid in (} . $all_authids . q{)
});

$sth_auth->execute();
while( my $row = $sth_auth->fetchrow_hashref ) {
	$auth_header->{ $row->{authid} } = $row->{full_name};
	$row->{department} =~ s/, Filozofski fakultet u Zagrebu\s*// || next;
	$row->{department} =~ s/^.+\.\s*//;
	push @{ $auth_department->{ $row->{department} } }, $row->{authid};
	warn dump( $row );
	push @authors, $row;

}

my $category_label;
my $sth_categories = $dbh->prepare(q{
select authorised_value, lib from authorised_values where category = 'BIBCAT'
});
$sth_categories->execute();
while( my $row = $sth_categories->fetchrow_hashref ) {
	$category_label->{ $row->{authorised_value} } = $row->{lib};

}
#warn dump( $category_label );

sub html_title {
	return qq|<html>
<head>
<meta charset="UTF-8">
<title>|, join(" ", @_), qq|</title>
<link href="style.css" type="text/css" rel="stylesheet" />
</head>
<body>
|;
}

sub html_end {
	return qq|</body>\n</html\n|;
}

my $biblio_html;

sub biblioitem_html {
	my $biblionumber = shift;

	return $biblio_html->{$biblionumber} if exists $biblio_html->{$biblionumber};

	my $xmlrecord = $marcxml->{$biblionumber} || die "missing $biblionumber marcxml";

	my $parser = XML::LibXML->new();
	$parser->recover_silently(0); # don't die when you find &, >, etc
    my $source = $parser->parse_string($xmlrecord);
	my $style_doc = $parser->parse_file($xslfilename);

	my $xslt = XML::LibXSLT->new();
	my $parsed = $xslt->parse_stylesheet($style_doc);
	my $transformed = $parsed->transform($source);
	return $biblio_html->{$biblionumber} = $parsed->output_string( $transformed );
}


mkdir 'html' unless -d 'html';

open(my $index, '>:encoding(utf-8)', 'html/index.new');
print $index html_title('Bibliografija Filozogskog fakulteta');

my $first_letter = '';

foreach my $row ( sort { $a->{full_name} cmp $b->{full_name} } @authors ) {

	my $first = substr( $row->{full_name}, 0, 1 );
	if ( $first ne $first_letter ) {
		print $index qq{</ul>\n} if $first_letter;
		$first_letter = $first;
		print $index qq{<h1>$first</h1>\n<ul>\n};
	}
	print $index qq{<li><a href="}, $row->{authid}, qq{.html">}, $row->{full_name}, "</a></li>\n";

	my $path = "html/$row->{authid}";
	open(my $fh, '>:encoding(utf-8)', "$path.new");
	print $fh html_title($row->{full_name}, "bibliografija");
	foreach my $category ( sort keys %{ $authors->{ $row->{authid} } } ) {
 		my $label = $category_label->{$category} || 'Bez kategorije';
		print $fh qq|<h1>$label</h1>\n<ul>\n|;
		foreach my $biblionumber ( @{ $authors->{ $row->{authid} }->{$category} } ) {
			print $fh qq|<li>|,
				qq|<a href="https://koha.ffzg.hr/cgi-bin/koha/opac-detail.pl?biblionumber=$biblionumber">$biblionumber</a>|,
				biblioitem_html($biblionumber),
				qq|<a href="https://koha.ffzg.hr:8443/cgi-bin/koha/cataloguing/addbiblio.pl?biblionumber=$biblionumber">edit</a>|,
				qq|</li>\n|;
		}
		print $fh qq|</ul>\n|;
	}
	print $fh html_end;
	close($fh);
	rename "$path.new", "$path.html";

}

print $index html_end;
close($index);
rename 'html/index.new', 'html/index.html';

#print dump( $authors );

print dump( $auth_header );

print dump( $auth_department );


my $department_category_author;
foreach my $department ( sort keys %$auth_department ) {
	foreach my $authid ( sort @{ $auth_department->{$department} } ) {
		foreach my $category ( sort keys %{ $authors->{$authid} } ) {
			push @{ $department_category_author->{$department}->{$category} }, $authid;
		}
	}
}

print dump( $department_category_author );

mkdir 'html/departments' unless -d 'html/departments';

open(my $dep_fh, '>:encoding(utf-8)', 'html/departments/index.new');
print $dep_fh html_title('Odsijeci Filozofskog fakulteta u Zagrebu'), qq|<ul>\n|;
foreach my $department ( sort keys %$department_category_author ) {
	my $dep = $department || 'Nema odsjeka';
	my $dep_file = unac_string('utf-8',$dep);
	print $dep_fh qq|<li><a href="$dep_file.html">$dep</a></li>\n|;
	open(my $fh, '>:encoding(utf-8)', "html/departments/$dep_file.new");
	print $fh html_title($department . ' bibliografija');
	foreach my $category ( sort keys %{ $department_category_author->{$department} } ) {
 		my $label = $category_label->{$category} || 'Bez kategorije';
		print $fh qq|<h1>$label</h1>\n<ul>\n|;

		foreach my $authid ( @{ $department_category_author->{$department}->{$category} } ) {
			foreach my $biblionumber ( @{ $authors->{$authid}->{$category} } ) {
				print $fh qq|<li>|,
					qq|<a href="https://koha.ffzg.hr/cgi-bin/koha/opac-detail.pl?biblionumber=$biblionumber">$biblionumber</a>|,
					biblioitem_html($biblionumber),
					qq|<a href="https://koha.ffzg.hr:8443/cgi-bin/koha/cataloguing/addbiblio.pl?biblionumber=$biblionumber">edit</a>|,
					qq|</li>\n|;
			}
		}

		print $fh qq|</ul>|;
	}
	print $fh html_end;
	close($fh);
	rename "html/departments/$dep_file.new", "html/departments/$dep_file.html";
}
print $dep_fh qq|</ul>\n|, html_end;
close($dep_fh);
rename 'html/departments/index.new', 'html/departments/index.html';

