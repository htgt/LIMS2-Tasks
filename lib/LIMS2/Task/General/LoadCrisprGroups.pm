package LIMS2::Task::General::LoadCrisprGroups;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::LoadCrisprGroups::VERSION = '0.016';
}
## use critic

use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::LoadCrisprGroups

=head1 DESCRIPTION

This command creates crispr groups in LIMS2.
Required options:
- user: Name of user creating the plate
- gene_type: Gene type id, for example HGNC or MGI
- upload_file: CSV file containing crispr group data to be uploaded

The design plate data file is a csv file, with at least a column named gene,and 2 columns
for each crispr in the group representing the crispr_id and if its left_of_target or not.
Column follows:
- gene
- crispr_1
- left_1
- crispr_2
- left_2
...

gene can be gene id or marker symbol.
crispr can be lims2_crispr_id or wge_crispr_id.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use LIMS2::Model;
use MooseX::Types::Path::Class;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Load Crispr Groups from CSV file';
};

has gene_type => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Gene type id, for example HGNC or MGI',
    traits        => [ 'Getopt' ],
);

has upload_file => (
    is            => 'ro',
    isa           => 'Path::Class::File',
    traits        => [ 'Getopt' ],
    documentation => 'File holding crispr group data. Should contain a gene column and then pairs of columns (crispr_1, left_1; crispr_2, left_2; ...).',
    coerce        => 1,
    cmd_flag      => 'upload-file',
    required      => 1,
);

has user => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'User who is creating the plate',
    required      => 1,
);

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info( 'Uploading crispr group data from file ' . $self->upload_file );

    # from species, get the gene_type_id
    my $species;
    if ($self->gene_type eq 'MGI' ) {
        $species = 'Mouse';
    } elsif ($self->gene_type eq 'HGNC' ) {
        $species = 'Human';
    }

    # get default assembly for species
    my $assembly = $self->model->schema->resultset('SpeciesDefaultAssembly')->find(
        { species_id => $species }
    )->assembly_id;

    # read the csv file
    my $csv = Text::CSV->new();

    my $fh = $self->upload_file->openr or die( 'Can not open plate data file' );
    $csv->column_names( map {lc $_} @{ ($csv->getline( $fh )) } );

    while ( my $data = $csv->getline_hr( $fh ) ) {

        # get the gene_id
        my $gene_id = $self->model->retrieve_gene( { species => $species, search_term => $data->{gene} } )->{gene_id};

        my @crispr_group;
        # get the crisprs, starting on crispr 1
        my $count = 1;
        while ( $count ) {
            if ( $data->{"crispr_$count"} ) {
                my $crispr_id = $data->{"crispr_$count"};
                my $crispr;
                try {
                    $crispr = $self->model->retrieve_crispr( { id => $crispr_id } )->seq // '';
                };

                # if the crispr can't be found, import it from wge
                unless ($crispr) {
                    $self->log->debug( 'Importing crispr ' . $crispr_id . ' from WGE' );
                    my @crispr_lims = $self->model->import_wge_crisprs( [ $crispr_id ], $species, $assembly );
                    $crispr_id = $crispr_lims[0]->{lims2_id};
                }
                $crispr_group[$count-1]->{crispr_id} = $crispr_id;
                $crispr_group[$count-1]->{left_of_target} = $data->{"left_$count"};

                # next crispr
                $count++;
            } else {
                $self->log->debug( 'Creating crispr group for gene' . $gene_id );
                $self->model->txn_do(
                    sub {
                        $self->model->create_crispr_group({
                            gene_id => $gene_id,
                            gene_type_id => $self->gene_type,
                            crisprs => \@crispr_group,
                        });
                        unless ( $self->commit ) {
                            $self->model->txn_rollback;
                        }
                    }
                );

                undef @crispr_group;
                undef $count;
            }
        }
    }

    return;
}


__PACKAGE__->meta->make_immutable;

1;

__END__
