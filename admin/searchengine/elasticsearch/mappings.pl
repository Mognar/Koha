#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use CGI;
use Scalar::Util qw(looks_like_number);
use List::Util qw( first );
use C4::Koha;
use C4::Output;
use C4::Auth;

use Koha::SearchEngine::Elasticsearch;
use Koha::SearchEngine::Elasticsearch::Indexer;
use Koha::SearchMarcMaps;
use Koha::SearchFields;
use Koha::Caches;

use Try::Tiny;

my $input = new CGI;
my ( $template, $borrowernumber, $cookie ) = get_template_and_user(
    {   template_name   => 'admin/searchengine/elasticsearch/mappings.tt',
        query           => $input,
        type            => 'intranet',
        authnotrequired => 0,
        flagsrequired   => { parameters => 'manage_search_engine_config' },
    }
);

my $index = $input->param('index') || 'biblios';
my $op    = $input->param('op')    || 'list';
my @messages;

my $database = Koha::Database->new();
my $schema   = $database->schema;

my $marc_type = lc C4::Context->preference('marcflavour');

my @index_names = ($Koha::SearchEngine::Elasticsearch::BIBLIOS_INDEX, $Koha::SearchEngine::Elasticsearch::AUTHORITIES_INDEX);

my $update_mappings = sub {
    for my $index_name (@index_names) {
        my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $index_name });
        try {
            $indexer->update_mappings();
        } catch {
            my $conf = $indexer->get_elasticsearch_params();
            push @messages, {
                type => 'error',
                code => 'error_on_update_es_mappings',
                message => $_[0],
                index => $conf->{index_name},
            };
        };
    }
};

my $cache = Koha::Caches->get_instance();
my $clear_cache = sub {
    $cache->clear_from_cache('elasticsearch_search_fields_staff_client');
    $cache->clear_from_cache('elasticsearch_search_fields_opac');
};

if ( $op eq 'edit' ) {

    $schema->storage->txn_begin;

    my @field_name = $input->multi_param('search_field_name');
    my @field_label = $input->multi_param('search_field_label');
    my @field_type = $input->multi_param('search_field_type');
    my @field_weight = $input->multi_param('search_field_weight');
    my @field_staff_client = $input->multi_param('search_field_staff_client');
    my @field_opac = $input->multi_param('search_field_opac');

    my @index_name          = $input->multi_param('mapping_index_name');
    my @search_field_name   = $input->multi_param('mapping_search_field_name');
    my @mapping_sort        = $input->multi_param('mapping_sort');
    my @mapping_facet       = $input->multi_param('mapping_facet');
    my @mapping_suggestible = $input->multi_param('mapping_suggestible');
    my @mapping_search      = $input->multi_param('mapping_search');
    my @mapping_marc_field  = $input->multi_param('mapping_marc_field');
    my @faceted_field_names = $input->multi_param('display_facet');

    eval {

        for my $i ( 0 .. scalar(@field_name) - 1 ) {
            my $field_name = $field_name[$i];
            my $field_label = $field_label[$i];
            my $field_type = $field_type[$i];
            my $field_weight = $field_weight[$i];
            my $field_staff_client = $field_staff_client[$i];
            my $field_opac = $field_opac[$i];

            my $search_field = Koha::SearchFields->find( { name => $field_name }, { key => 'name' } );
            $search_field->label($field_label);
            $search_field->type($field_type);

            if (!length($field_weight)) {
                $search_field->weight(undef);
            }
            elsif ($field_weight <= 0 || !looks_like_number($field_weight)) {
                push @messages, { type => 'error', code => 'invalid_field_weight', 'weight' => $field_weight };
            }
            else {
                $search_field->weight($field_weight);
            }
            $search_field->staff_client($field_staff_client ? 1 : 0);
            $search_field->opac($field_opac ? 1 : 0);

            my $facet_order = first { $faceted_field_names[$_] eq $field_name } 0 .. $#faceted_field_names;
            $search_field->facet_order(defined $facet_order ? $facet_order + 1 : undef);
            $search_field->store;
        }

        Koha::SearchMarcMaps->search( { marc_type => $marc_type, } )->delete;
        my @facetable_fields = Koha::SearchEngine::Elasticsearch->get_facetable_fields();
        my @facetable_field_names = map { $_->name } @facetable_fields;

        for my $i ( 0 .. scalar(@index_name) - 1 ) {
            my $index_name          = $index_name[$i];
            my $search_field_name   = $search_field_name[$i];
            my $mapping_marc_field  = $mapping_marc_field[$i];
            my $mapping_facet       = $mapping_facet[$i];
            $mapping_facet = ( grep {/^$search_field_name$/} @facetable_field_names ) ? $mapping_facet : 0;
            my $mapping_suggestible = $mapping_suggestible[$i];
            my $mapping_sort        = $mapping_sort[$i] eq 'undef' ? undef : $mapping_sort[$i];
            my $mapping_search      = $mapping_search[$i];

            my $search_field = Koha::SearchFields->find({ name => $search_field_name }, { key => 'name' });
            # TODO Check mapping format
            my $marc_field = Koha::SearchMarcMaps->find_or_create({
                index_name => $index_name,
                marc_type => $marc_type,
                marc_field => $mapping_marc_field
            });
            $search_field->add_to_search_marc_maps($marc_field, {
                facet => $mapping_facet,
                suggestible => $mapping_suggestible,
                sort => $mapping_sort,
                search => $mapping_search
            });
        }
    };
    if ($@) {
        push @messages, { type => 'error', code => 'error_on_update', message => $@, };
        $schema->storage->txn_rollback;
    } else {
        push @messages, { type => 'message', code => 'success_on_update' };
        $schema->storage->txn_commit;
        $clear_cache->();
        $update_mappings->();
    }
}
elsif( $op eq 'reset_confirmed' ) {
    Koha::SearchMarcMaps->delete;
    Koha::SearchFields->delete;
    Koha::SearchEngine::Elasticsearch->reset_elasticsearch_mappings;
    $clear_cache->();
    push @messages, { type => 'message', code => 'success_on_reset' };
}
elsif( $op eq 'reset_confirm' ) {
    $template->param( reset_confirm => 1 );
}

my @indexes;

for my $index_name (@index_names) {
    my $indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $index_name });
    if (!$indexer->is_index_status_ok) {
        my $conf = $indexer->get_elasticsearch_params();
        if ($indexer->is_index_status_reindex_required) {
            push @messages, {
                type => 'error',
                code => 'reindex_required',
                index => $conf->{index_name},
            };
        }
        elsif($indexer->is_index_status_recreate_required) {
            push @messages, {
                type => 'error',
                code => 'recreate_required',
                index => $conf->{index_name},
            };
        }
    }
}

my @facetable_fields = Koha::SearchEngine::Elasticsearch->get_facetable_fields();
for my $index_name (@index_names) {
    my $search_fields = Koha::SearchFields->search(
        {
            'search_marc_map.index_name' => $index_name,
            'search_marc_map.marc_type' => $marc_type,
        },
        {
            join => { search_marc_to_fields => 'search_marc_map' },
            '+select' => [
                'search_marc_to_fields.facet',
                'search_marc_to_fields.suggestible',
                'search_marc_to_fields.sort',
                'search_marc_to_fields.search',
                'search_marc_map.marc_field'
            ],
            '+as' => [
                'facet',
                'suggestible',
                'sort',
                'search',
                'marc_field'
            ],
            order_by => { -asc => [qw/name marc_field/] }
         }
     );

    my @mappings;
    my @facetable_field_names = map { $_->name } @facetable_fields;

    while ( my $s = $search_fields->next ) {
        my $name = $s->name;
        push @mappings, {
            search_field_name  => $name,
            search_field_label => $s->label,
            search_field_type  => $s->type,
            marc_field         => $s->get_column('marc_field'),
            sort               => $s->get_column('sort') // 'undef', # To avoid warnings "Use of uninitialized value in lc"
            suggestible        => $s->get_column('suggestible'),
            search             => $s->get_column('search'),
            facet              => $s->get_column('facet'),
            is_facetable       => ( grep {/^$name$/} @facetable_field_names ) ? 1 : 0,
        };
    }

    push @indexes, { index_name => $index_name, mappings => \@mappings };
}

my $search_fields = Koha::SearchFields->search( {}, { order_by => ['name'] } );
my @all_search_fields;
while ( my $search_field = $search_fields->next ) {
    my $search_field_unblessed = $search_field->unblessed;
    $search_field_unblessed->{mapped_biblios} = 1 if $search_field->is_mapped_biblios;
    push @all_search_fields, $search_field_unblessed;
}

$template->param(
    indexes           => \@indexes,
    all_search_fields => \@all_search_fields,
    facetable_fields  => \@facetable_fields,
    messages          => \@messages,
);

output_html_with_http_headers $input, $cookie, $template->output;
