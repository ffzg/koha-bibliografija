
function toc_count_update(type_cat) {
	var selector = '#toc-count-'+type_cat.replace(/\./g,'-');
	var e = $(selector);
	if ( ! e )  {
		console.error(selector, 'not found');
		return;
	}
	var old_val = parseInt( e.text() );
	var new_val = parseInt( type_cat_count[type_cat] );

	if ( old_val != new_val ) {
		e.text(new_val);
		console.debug( selector, 'old', old_val, 'new', new_val);

		var cat = type_cat.split('-')[0];
		var val = type_cat_count['_toc_count'][cat] += new_val - old_val;
		console.log(cat, val);
		$('#toc-count-'+cat).text(val);

	}
}

function year_show(year) {
	$('.y'+year).show();
	console.debug('show', year);
	for(var type_cat in years[year]) {
//console.log('year_show', type_cat, type_cat_count[ type_cat ], years[year][type_cat] );
		if ( ( type_cat_count[ type_cat ] += parseInt(years[year][type_cat]) ) > 0 ) {
			$('a[name="'+type_cat+'"]').show();
			console.debug(type_cat, 'show');
		}
		toc_count_update(type_cat);
	}
}

function year_hide(year) {
	$('.y'+year).hide();
	console.debug('hide', year);
	for(var type_cat in years[year]) {
//console.log('year_hide', type_cat, type_cat_count[ type_cat ], years[year][type_cat] );
		if ( ( type_cat_count[ type_cat ] -= parseInt(years[year][type_cat]) ) == 0 ) {
			$('a[name="'+type_cat+'"]').hide();
			console.debug(type_cat, 'hide');
		}
		toc_count_update(type_cat);
	}
}

function toggle_year(year, el) {
	if ( el.checked ) {
		year_show(year);
	} else {
		year_hide(year);
	}
}

function all_years( turn_on ) {
	$('input[name=year_selection]').each( function(i,el) {
		if ( turn_on ) {
			if ( ! el.checked ) {
				el.checked = true;
				year_show( el.value );
			}
		} else {
			if ( el.checked ) {
				el.checked = false;
				year_hide( el.value );
			}
		}
	} );
}

$(document).ready( function() {
	console.info('ready');

	$('input[name=year_selection]').each( function(i, el) {
		var year = el.value;
		console.debug( 'on load', year, el.checked );
		if (! el.checked) year_hide(year);
	});

});
