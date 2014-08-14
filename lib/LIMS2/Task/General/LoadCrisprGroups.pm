package LIMS2::Task::General::LoadCrisprGroups;
use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::LoadCrisprGroups

=head1 DESCRIPTION

This command creates Design Plates in LIMS2.
Required options:
- plate: Name of design plate to create
- user: Name of user creating the plate
- design-plate-data: file containing data about the design plate wells.

The design plate data file is a csv file, with 2 columns:
- well_name
- design_id

The file must have these column headers.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use LIMS2::Model;
use MooseX::Types::Path::Class;
use namespace::autoclean;

use Smart::Comments;

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
                $self->model->create_crispr_group({
                    gene_id => $gene_id,
                    gene_type_id => $self->gene_type,
                    crisprs => \@crispr_group,
                });

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
