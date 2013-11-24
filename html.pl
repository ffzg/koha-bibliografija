#!/usr/bin/perl

# LC_COLLATE=hr_HR.utf8 KOHA_CONF=/etc/koha/sites/ffzg/koha-conf.xml ./html.pl

use warnings;
use strict;

use DBI;
use Data::Dump qw(dump);
use autodie;
use locale;
use Text::Unaccent;
use Carp qw(confess);

use lib '/srv/koha_ffzg';
use C4::Context;
use XML::LibXML;
use XML::LibXSLT;

my $dbh = C4::Context->dbh;

sub debug {
	my ($title, $data) = @_;
	print "# $title ",dump($data), $/;
}

my $xslfilename = 'compact.xsl';

my $auth_header;
my $auth_department;
my @authors;

my $skip;

my $sth_auth = $dbh->prepare(q{
select
	authid,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="a"]') as full_name,
	ExtractValue(marcxml,'//datafield[@tag="680"]/subfield[@code="a"]') as department
from auth_header
});

$sth_auth->execute();
while( my $row = $sth_auth->fetchrow_hashref ) {
	if ( $row->{department} !~ m/Filozofski fakultet u Zagrebu/ ) {
		push @{ $skip->{nije_ffzg} }, $row;
		next;
	}
	$auth_header->{ $row->{authid} } = $row->{full_name};
	$row->{department} =~ s/, Filozofski fakultet u Zagrebu.*$//;
	$row->{department} =~ s/^.+\.\s*//;
#	warn dump( $row );
	push @{ $auth_department->{ $row->{department} } }, $row->{authid};
	push @authors, $row;

}

debug 'auth_department' => $auth_department;


my $authors;
my $marcxml;

my $sth_select_authors  = $dbh->prepare(q{
select
	biblionumber,
	itemtype,
	marcxml
from biblioitems
where
	agerestriction > 0
});

=for sql
--	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="9"]') as first_author,
--	ExtractValue(marcxml,'//datafield[@tag="700"]/subfield[@code="9"]') as other_authors,
--	ExtractValue(marcxml,'//datafield[@tag="942"]/subfield[@code="t"]') as category,

--	and SUBSTR(ExtractValue(marcxml,'//controlfield[@tag="008"]'),8,4) between 2008 and 2013
-- order by SUBSTR(ExtractValue(marcxml,'//controlfield[@tag="008"]'),8,4) desc
=cut

my $biblio_year;
my $type_stats;

my $parser = XML::LibXML->new();
$parser->recover_silently(0); # don't die when you find &, >, etc
my $style_doc = $parser->parse_file($xslfilename);
my $xslt = XML::LibXSLT->new();
my $parsed = $xslt->parse_stylesheet($style_doc);

my $biblio_html;

open(my $xml_fh, '>', '/tmp/bibliografija.xml') if $ENV{XML};

sub biblioitem_html {
	my $biblionumber = shift;

	return $biblio_html->{$biblionumber} if exists $biblio_html->{$biblionumber};

	my $xmlrecord = $marcxml->{$biblionumber} || confess "missing $biblionumber marcxml";

	print $xml_fh $xmlrecord if $ENV{XML};

	my $source = eval { $parser->parse_string($xmlrecord) };
	if ( $@ ) {
#		warn "SKIP $biblionumber corrupt XML";
		push @{ $skip->{XML_corrupt} }, $biblionumber;
		return;
	}

	my $transformed = $parsed->transform($source);
	$biblio_html->{$biblionumber} = $parsed->output_string( $transformed );

	return ( $biblio_html->{$biblionumber}, $source ) if wantarray;
	return $biblio_html->{$biblionumber};
}

$sth_select_authors->execute();
while( my $row = $sth_select_authors->fetchrow_hashref ) {
#	warn dump($row),$/;

	my $biblio;

	$marcxml->{ $row->{biblionumber} } = $row->{marcxml};

	my ( undef, $doc ) = biblioitem_html( $row->{biblionumber} );
	if ( ! $doc ) {
		warn "ERROR can't parse MARCXML ", $row->{biblionumber}, " ", $row->{marcxml}, "\n";
		next;
	}

	my $root = $doc->documentElement;
=for leader
	my @leaders = $root->getElementsByLocalName('leader');
	if (@leaders) {
		my $leader = $leaders[0]->textContent;
		warn "leader $leader\n";
	}
=cut

	my $extract = {
		'008' => undef,
		'100' => '9',
		'700' => '(9|4)',
		'942' => 't'
	};

	my $data;

	foreach my $elt ($root->getChildrenByLocalName('*')) {
		my $tag = $elt->getAttribute('tag');
		next if ! $tag;
		next unless exists $extract->{ $tag };

        if ($elt->localname eq 'controlfield') {
			if ( $tag eq '008' ) {
				 $biblio_year->{ $row->{biblionumber} } = $elt->textContent;
			}
			next;
        } elsif ($elt->localname eq 'datafield') {
			my $sf_data;
            foreach my $sfelt ($elt->getChildrenByLocalName('subfield')) {
                my $sf = $sfelt->getAttribute('code');
				next unless $sf =~ m/$extract->{$tag}/;
				if ( exists $sf_data->{$sf} ) {
					$sf_data->{$sf} .= " " . $sfelt->textContent();
				} else {
 					$sf_data->{$sf} = $sfelt->textContent();
				}
			}
			push @{ $data->{$tag} }, $sf_data if $sf_data;
        }
    }

#	warn "# ", $row->{biblionumber}, " data ",dump($data);

	my $category = $data->{942}->[0]->{'t'};
	if ( ! $category ) {
#		warn "# SKIP ", $row->{biblionumber}, " no category in ", dump($data);
		push @{ $skip->{no_category} }, $row->{biblionumber};
		next;
	}


	my $have_100 = 1;

	if ( exists $data->{100} ) {
			my @first_author = map { $_->{'9'} } @{ $data->{100} };
			foreach my $authid ( @first_author ) {
				push @{ $authors->{$authid}->{aut}->{ $category } }, $row->{biblionumber};
			}
	} else {
		$have_100 = 0;
	}

	my $have_edt;

	if ( exists $data->{700} ) {
			foreach my $auth ( @{ $data->{700} } ) {
				my $authid = $auth->{9} || next;
				my $type   = $auth->{4} || next; #die "no 4 in ",dump($data);

				$type_stats->{$type}++;

				if ( $type =~ m/(edt|trl|com|ctb)/ ) {
					push @{ $authors->{$authid}->{sec}->{ $category } }, $row->{biblionumber};
					push @{ $authors->{$authid}->{$1}->{ $category } }, $row->{biblionumber};
				} elsif ( $type =~ m/aut/ ) {
					if ( ! $have_100 ) {
						$have_edt = grep { exists $_->{4} && $_->{4} =~ m/edt/ } @{ $data->{700} } if ! defined $have_edt;
						if ( $have_edt ) {
							$skip->{ have_700_edt }->{ $row->{biblionumber} }++;
						} else {
							push @{ $authors->{$authid}->{aut}->{ $category } }, $row->{biblionumber};
						}
					} else {
						push @{ $authors->{$authid}->{aut}->{ $category } }, $row->{biblionumber};
					}
				} else {
#					warn "# SKIP ", $row->{biblionumber}, ' no 700$4 in ', dump($data);
					$skip->{ 'no_700$4' }->{ $row->{biblionumber} }++;
				}
			}
	}

}

debug 'authors' => $authors;
debug 'type_stats' => $type_stats;
debug 'skip' => $skip;

my $category_label;
my $sth_categories = $dbh->prepare(q{
select authorised_value, lib from authorised_values where category = 'BIBCAT'
});
$sth_categories->execute();
while( my $row = $sth_categories->fetchrow_hashref ) {
	$category_label->{ $row->{authorised_value} } = $row->{lib};

}
debug 'category_label' => $category_label;

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

mkdir 'html' unless -d 'html';

open(my $index, '>:encoding(utf-8)', 'html/index.new');
print $index html_title('Bibliografija Filozofskog fakulteta');

my $first_letter = '';

debug 'authors' => \@authors;

sub li_biblio {
	my ($biblionumber) = @_;
	return qq|<li>|,
		qq|<a href="https://koha.ffzg.hr/cgi-bin/koha/opac-detail.pl?biblionumber=$biblionumber">$biblionumber</a>|,
		biblioitem_html($biblionumber),
		qq|<a href="https://koha.ffzg.hr:8443/cgi-bin/koha/cataloguing/addbiblio.pl?biblionumber=$biblionumber">edit</a>|,
		qq|</li>\n|;
}

sub author_html {
	my ( $fh, $authid, $type, $label ) = @_;

	return unless exists $authors->{$authid}->{$type};

	print $fh qq|<h2>$label</h2>\n|;

	foreach my $category ( sort keys %{ $authors->{$authid}->{$type} } ) {
		my $label = $category_label->{$category} || 'Bez kategorije';
		print $fh qq|<h3>$label</h3>\n<ul>\n|;
		foreach my $biblionumber ( @{ $authors->{$authid}->{$type}->{$category} } ) {
			print $fh li_biblio( $biblionumber );
		}
		print $fh qq|</ul>\n|;
	}
}

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
	print $fh qq|<h1>$row->{full_name} - bibliografija za razdoblje 2008-2013</h1>|;

	author_html( $fh, $row->{authid}, 'aut' => 'Primarno autorstvo' );
	author_html( $fh, $row->{authid}, 'sec' => 'Sekundarno autorstvo' );

	print $fh html_end;
	close($fh);
	rename "$path.new", "$path.html";

}

print $index html_end;
close($index);
rename 'html/index.new', 'html/index.html';

debug 'auth_header' => $auth_header;


my $department_category_author;
foreach my $department ( sort keys %$auth_department ) {
	foreach my $authid ( sort @{ $auth_department->{$department} } ) {
		my   @categories = keys %{ $authors->{$authid}->{aut} };
		push @categories,  keys %{ $authors->{$authid}->{sec} };
		foreach my $category ( sort @categories ) {
			push @{ $department_category_author->{$department}->{$category} }, $authid;
		}
	}
}

debug 'department_category_author' => $department_category_author;

mkdir 'html/departments' unless -d 'html/departments';

open(my $dep_fh, '>:encoding(utf-8)', 'html/departments/index.new');
print $dep_fh html_title('Odsijeci Filozofskog fakulteta u Zagrebu'), qq|<ul>\n|;
foreach my $department ( sort keys %$department_category_author ) {
	my $dep = $department || 'Nema odsjeka';
	my $dep_file = unac_string('utf-8',$dep);
	print $dep_fh qq|<li><a href="$dep_file.html">$dep</a></li>\n|;
	open(my $fh, '>:encoding(utf-8)', "html/departments/$dep_file.new");

	print $fh html_title($department . ' bibliografija');
	print $fh qq|<h1>$department bibliografija</h1>\n|;

	print $fh qq|<h2>Primarno autorstvo</h2>\n|;

	foreach my $category ( sort keys %{ $department_category_author->{$department} } ) {

		my @authids = @{ $department_category_author->{$department}->{$category} };
		next unless @authids;

		my @biblionumber = map { @{ $authors->{$_}->{aut}->{$category} } } grep { exists $authors->{$_}->{aut}->{$category} } @authids;

		next unless @biblionumber;

 		my $label = $category_label->{$category} || 'Bez kategorije';
		print $fh qq|<h3>$label</h3>\n<ul>\n|;

		print $fh li_biblio( $_ ) foreach @biblionumber;

		print $fh qq|</ul>|;
	}


	print $fh qq|<h2>Sekundarno autorstvo</h2>\n|;

	foreach my $category ( sort keys %{ $department_category_author->{$department} } ) {

		my @authids = @{ $department_category_author->{$department}->{$category} };
		next unless @authids;

		my @biblionumber = map { @{ $authors->{$_}->{sec}->{$category} } } grep { exists $authors->{$_}->{sec}->{$category} } @authids;

		next unless @biblionumber;

 		my $label = $category_label->{$category} || 'Bez kategorije';
		print $fh qq|<h3>$label</h3>\n<ul>\n|;

		print $fh li_biblio( $_ ) foreach @biblionumber;

		print $fh qq|</ul>|;
	}


	print $fh html_end;
	close($fh);
	rename "html/departments/$dep_file.new", "html/departments/$dep_file.html";
}
print $dep_fh qq|</ul>\n|, html_end;
close($dep_fh);
rename 'html/departments/index.new', 'html/departments/index.html';

my $azvo_stat;

foreach my $department ( sort keys %$department_category_author ) {
	foreach my $category ( sort keys %{ $department_category_author->{$department} } ) {
		foreach my $authid ( @{ $department_category_author->{$department}->{$category} } ) {
			foreach my $type ( keys %{ $authors->{$authid} } ) {
				next unless exists $authors->{$authid}->{$type}->{$category};
				$azvo_stat->{ $department }->{ $category }->{ $type } += $#{ $authors->{$authid}->{$type}->{$category} } + 1;
			}
		}
	}
}

debug 'azvo_stat' => $azvo_stat;

=for later
open(my $fh, '>', 'html/azvo.new');



close($fh);
rename 'html/azvo.new', 'html/azvo.html';
=cut

