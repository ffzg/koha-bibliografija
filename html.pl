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
use utf8;

use lib '/srv/koha_ffzg';
use C4::Context;
use XML::LibXML;
use XML::LibXSLT;

my $dbh = C4::Context->dbh;

sub debug {
	my ($title, $data) = @_;
	print "# $title ",dump($data), $/ if $ENV{DEBUG};
}

my $xslfilename = 'compact.xsl';

my $azvo_group_title = {
'znanstveno nastavni' => qr/(profesor|docent|znanstveni)/i,
'lektori i predavači' => qr/(lektor|predavač)/i,
'asistenti i novaci' => qr/(asistent|novak)/i,
};

my $department_groups = {
'AAA_humanističke'		=> qr/(anglistiku|arheologiju|antropologiju|filozofiju|fonetiku|germanistiku|hungarologiju|indologiju|slavenske|filologiju|komparativnu|kroatistiku|lingvistiku|povijest|romanistiku|talijanistiku)/i,
'AAB_društvene'			=> qr/(informacijske|pedagogiju|psihologiju|sociologiju)/i,
};

my $auth_header;
my $auth_department;
my $auth_group;
my @authors;
my $department_in_sum;
my $department_in_group;

my $skip;

my $sth_auth = $dbh->prepare(q{
select
	authid,
	ExtractValue(marcxml,'//datafield[@tag="100"]/subfield[@code="a"]') as full_name,
	ExtractValue(marcxml,'//datafield[@tag="680"]/subfield[@code="a"]') as department,
	ExtractValue(marcxml,'//datafield[@tag="680"]/subfield[@code="i"]') as academic_title
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
	$row->{department} =~ s/\s+$//s;
	my $group;
	foreach my $title ( keys %$azvo_group_title ) {
		if ( $row->{academic_title} =~ $azvo_group_title->{$title} ) {
			$group = $title;
			last;
		}
	}
	if ( $group ) {
		$row->{academic_group} = $group;
		$auth_group->{ $row->{authid} } = $group;
		$skip->{group_stat}->{$group}++;
	} else {
		push @{ $skip->{no_academic_group} }, $row;
	}

#	warn "# ", dump( $row );
	push @{ $auth_department->{ $row->{department} } }, $row->{authid};
	push @authors, $row;
	$department_in_sum->{ $row->{department} }++;
	foreach my $name ( keys %$department_groups ) {
		my $regex = $department_groups->{$name};
		if ( $row->{department} =~ $regex ) {
			$department_in_group->{ $row->{department} } = $name;
			last;
		}
	}
}

debug 'department_in_group' => $department_in_group;

foreach my $department ( keys %$department_in_sum ) {
	$department_in_sum->{$department} = 0 unless $department =~ m/(centar|croaticum|katedra|odsjek)/i;
}

debug 'auth_department' => $auth_department;
debug 'auth_group' => $auth_group;
debug 'department_in_sum' => $department_in_sum;


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
my $biblio_parsed;
my $biblio_data;
my $biblio_author_external;

open(my $xml_fh, '>', '/tmp/bibliografija.xml') if $ENV{XML};

sub biblioitem_html {
	my ($biblionumber, $parse_only) = @_;

	return $biblio_html->{$biblionumber} if exists $biblio_html->{$biblionumber} && ! $parse_only;

	my $xmlrecord = $marcxml->{$biblionumber} || confess "missing $biblionumber marcxml";

	print $xml_fh $xmlrecord if $ENV{XML};

	my $source = eval { $parser->parse_string($xmlrecord) };
	if ( $@ ) {
#		warn "SKIP $biblionumber corrupt XML";
		push @{ $skip->{XML_corrupt} }, $biblionumber;
		return;
	}

	if ( $parse_only ) {
		$biblio_parsed->{$biblionumber} = $source;
		return $source;
	}

	my $transformed = $parsed->transform($source);
	$biblio_html->{$biblionumber} = $parsed->output_string( $transformed );

	delete $biblio_parsed->{$biblionumber};

	return $biblio_html->{$biblionumber};
}

$sth_select_authors->execute();
while( my $row = $sth_select_authors->fetchrow_hashref ) {
#	warn dump($row),$/;

	my $biblio;

	$marcxml->{ $row->{biblionumber} } = $row->{marcxml};

	my $doc = biblioitem_html( $row->{biblionumber}, 1 );
	if ( ! $doc ) {
#		warn "ERROR can't parse MARCXML ", $row->{biblionumber}, " ", $row->{marcxml}, "\n";
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
		'100' => '(9|a)',
		'680' => 'i',
		'700' => '(9|4|a)',
		'942' => '(t|r|v)'
	};

	my $data;

	foreach my $elt ($root->getChildrenByLocalName('*')) {
		my $tag = $elt->getAttribute('tag');
		next if ! $tag;
		next unless exists $extract->{ $tag };

        if ($elt->localname eq 'controlfield') {
			if ( $tag eq '008' ) {
				my $content = $elt->textContent;
				my $year = substr($content, 7, 4 );
				if ( $year !~ m/^\d+$/ ) {
					$year = 0;
					push @{ $skip->{invalid_year} }, $row->{biblionumber};
				}
				$biblio_year->{ $row->{biblionumber} } = $data->{year} = $year;
				$data->{'008'} = $content;
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

	if ( $data->{year} < 2008 ) {
		push @{ $skip->{year_lt_2008} }, $row->{biblionumber};
		next;
	} elsif ( $data->{year} > 2013 ) {
		push @{ $skip->{year_gt_2013} }, $row->{biblionumber};
		next;
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
			my @first_author =
				map { $_->{'9'} }
				grep {
					if ( ! exists $_->{9} ) {
						$biblio_author_external->{ $row->{biblionumber} }++;
						0;
					} elsif ( exists $auth_header->{ $_->{9} } ) {
						1; # from FFZXG
					} else {
						0;
					}
				}
				@{ $data->{100} };
			foreach my $authid ( @first_author ) {
				push @{ $authors->{$authid}->{aut}->{ $category } }, $row->{biblionumber};
			}
	} else {
		$have_100 = 0;
	}

	my $have_edt;

	if ( exists $data->{700} ) {
			my @other_authors =
				grep {
					if ( ! exists $_->{9} ) {
						$biblio_author_external->{ $row->{biblionumber} }++;
						0;
					} elsif ( exists $auth_header->{ $_->{9} } ) {
						1; # from FFZXG
					} else {
						0;
					}
				}
				@{ $data->{700} };
			foreach my $auth ( @other_authors ) {
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
			delete $data->{700};
	}

	$biblio_data->{ $row->{biblionumber} } = $data;

}

debug 'authors' => $authors;
debug 'type_stats' => $type_stats;
debug 'skip' => $skip;
debug 'biblio_year' => $biblio_year;
debug 'biblio_data' => $biblio_data;
debug 'biblio_author_external' => $biblio_author_external;

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
	return qq|</body>\n</html>\n|;
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
	author_html( $fh, $row->{authid}, 'sec' => 'Uredništva, prijevodi, krička izdanja' );

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
			push @{ $department_category_author->{'AAZ_ukupno'}->{$category} }, $authid if $department_in_sum->{$department};
			if ( my $group = $department_in_group->{ $department } ) {
				push @{ $department_category_author->{$group}->{$category} }, $authid;
			} else {
				$skip->{'department_not_in_group'}->{ $department }++;
			}
		}
	}
}

debug 'department_category_author' => $department_category_author;

mkdir 'html/departments' unless -d 'html/departments';

sub unique_biblionumber {
	my @v = @_;
	my $u;
	$u->{$_}++ foreach @v;
	return sort { $biblio_year->{$b} <=> $biblio_year->{$a} || $a <=> $b } keys %$u;
}

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

		my @biblionumber = unique_biblionumber map { @{ $authors->{$_}->{aut}->{$category} } } grep { exists $authors->{$_}->{aut}->{$category} } @authids;
		my $unique;
		$unique->{$_}++ foreach @biblionumber;

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

		my @biblionumber = unique_biblionumber map { @{ $authors->{$_}->{sec}->{$category} } } grep { exists $authors->{$_}->{sec}->{$category} } @authids;

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

my $azvo_stat_biblio;

foreach my $department ( sort keys %$department_category_author ) {
	foreach my $category ( sort keys %{ $department_category_author->{$department} } ) {
		foreach my $authid ( @{ $department_category_author->{$department}->{$category} } ) {
			my $group = $auth_group->{$authid};
			if ( ! $group ) {
				push @{ $skip->{no_auth_group} }, $authid;
				next;
			}
			foreach my $type ( keys %{ $authors->{$authid} } ) {
				next unless exists $authors->{$authid}->{$type}->{$category};
				push @{ $azvo_stat_biblio->{ $department }->{ $category }->{ $type }->{$group} },  @{ $authors->{$authid}->{$type}->{$category} };
				push @{ $azvo_stat_biblio->{ $department }->{ $category }->{ $type }->{''} },  @{ $authors->{$authid}->{$type}->{$category} };
			}
		}
		foreach my $type ( keys %{ $azvo_stat_biblio->{ $department }->{ $category } } ) {
			foreach my $group ( keys %{ $azvo_stat_biblio->{ $department }->{ $category }->{ $type } } ) {
				my @biblios = unique_biblionumber @{ $azvo_stat_biblio->{ $department }->{ $category }->{ $type }->{ $group } };
				$azvo_stat_biblio->{ $department }->{ $category }->{ $type }->{ $group } = [ @biblios ];
			}
		}
	}
}

debug 'azvo_stat_biblio' => $azvo_stat_biblio;

my @report_lines;
my @report_labels;

my $label;
my $sub_labels;
open(my $report, '<:encoding(utf-8)', 'AZVO.txt');
while( <$report> ) {
	chomp;
	if ( /^([^\t]+)\t+(.+)/ ) {
		$label = $1;
		push @report_labels, $label;
		my $type = [ map { m/\s+/ ? [ split(/\s+/,$_) ] : [ $_, 'aut' ] } split (/\s*\+\s*/, $2) ];
		push @report_lines, [ $label, @$type ];
	} elsif ( /^\t+([^\t]+):\t+(\d+)(\w*)\t*(.*)$/ ) {
		push @{ $sub_labels->{$label} }, [ $1, $2, $3, $4 ];
		my $sub_label = $1;
		pop (@report_labels) if ( $report_labels[ $#report_labels ] =~ m/^$label$/ ); # remove partial name
		push @report_labels, $label . $sub_label;
	} else {
		die "ERROR: [$_]\n";
	}
}

debug 'report_lines', \@report_lines;
debug 'sub_labels', $sub_labels;
debug 'report_labels', \@report_labels;

my @departments = ( sort { lc($a) cmp lc($b) } keys %$azvo_stat_biblio );

debug 'departments' => \@departments;

my $department2col;
$department2col->{ $departments[$_] } = $_ foreach ( 0 .. $#departments );
my $label2row;
$label2row->{ $report_labels[$_] } = $_ foreach ( 0 .. $#report_labels );

my $table;

sub table_count {
	my $label = shift @_;
	my $department = shift @_;
	my $group = shift @_;
	my @biblionumbers = @_;
	my $unique;
	$unique->{$_}++ foreach @biblionumbers;
	my @bibs = keys %$unique;
	$table->{ffzg}->{$group}->[ $label2row->{ $label } ]->[ $department2col->{$department} ] = scalar @bibs;
	$table->{external}->{$group}->[ $label2row->{ $label } ]->[ $department2col->{$department} ] = scalar grep { $biblio_author_external->{$_} } @bibs;
}

foreach my $group ( '', keys %$azvo_group_title ) {

foreach my $department ( @departments ) {
	foreach my $line ( @report_lines ) {
		my $label = $line->[0];
		my @biblionumbers;
		foreach ( 1 .. $#$line ) {
			my ( $category, $type ) = @{ $line->[ $_ ] };
			my $b = $azvo_stat_biblio->{ $department }->{$category}->{$type}->{$group};
			push @biblionumbers, @$b if $b;
		}
		if ( $sub_labels->{$label} ) {
			my $sub_stats;
			foreach my $biblionumber ( @biblionumbers ) {
				my $data = $biblio_data->{$biblionumber} || die "can't find biblionumber $biblionumber";
				foreach my $sub_label ( @{ $sub_labels->{$label} } ) {
					my ( $sub_label, $field, $sf, $regex ) = @$sub_label;
					if ( ! $regex ) {
						push @{ $sub_stats->{ $sub_label } }, $biblionumber;
						last;
					}
					if ( $field < 100 ) {
						if ( $data->{$field} =~ m/$regex/ ) {
							push @{ $sub_stats->{ $sub_label } }, $biblionumber;
							last;
						}
					} else {
						if ( exists $data->{$field}->[0]->{$sf} && $data->{$field}->[0]->{$sf} =~ m/$regex/ ) {
							push @{ $sub_stats->{ $sub_label } }, $biblionumber;
							last;
						}
					}
				}
			}
			foreach my $sub_label ( keys %$sub_stats ) {
				my $full_label = $label . $sub_label;
				table_count $full_label, $department, $group, @{ $sub_stats->{$sub_label} };
			}
		} else {
			table_count $label, $department, $group, @biblionumbers;
		}
	}
}

} # group

debug 'table', $table;

open(my $fh, '>:encoding(utf-8)', 'html/azvo.new');
open(my $fh2, '>:encoding(utf-8)', 'html/azvo2.new');

sub print_fh {
	print $fh @_;
	print $fh2 @_;
}

print $fh html_title('AZVO tablica - FFZG');
print $fh2 html_title('AZVO tablica - kolaboracija sa FFZG');

foreach my $group ( keys %{ $table->{ffzg} } ) {

		print_fh "<h1>$group</h1>" if $group;

		print_fh "<table border=1>\n";
		print_fh "<tr><th></th>";
		print_fh "<th>$_</th>" foreach @departments;
		print_fh "</tr>\n";

		foreach my $row ( 0 .. $#{ $table->{ffzg}->{$group} } ) {
			print_fh "<tr><th>", $report_labels[$row], "</th>\n";
 			foreach ( 0 .. $#departments ) {
				print_fh "<td>";
				print $fh $table->{ffzg}->{$group}->[ $row ]->[ $_ ] || '';
				print $fh2 $table->{external}->{$group}->[ $row ]->[ $_ ] || '';
				print_fh "</td>\n"
			}
			print_fh "</tr>\n";
		}

		print_fh "</table>\n";

} # group

print_fh html_end;
close($fh);
close($fh2);
rename 'html/azvo.new', 'html/azvo.html';
rename 'html/azvo2.new', 'html/azvo2.html';

