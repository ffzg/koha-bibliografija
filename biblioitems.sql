update biblioitems set agerestriction = ExtractValue(marcxml,'//datafield[@tag="942"]/subfield[@code="u"]') ;

create index biblioitems_agerestriction on biblioitems(agerestriction) ;

