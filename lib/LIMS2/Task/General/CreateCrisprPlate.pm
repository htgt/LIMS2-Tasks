package LIMS2::Task::General::CreateCrisprPlate;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CreateCrisprPlate::VERSION = '0.016';
}
## use critic

use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::CreateCrisprPlate

=head1 DESCRIPTION

This command creates Crispr Plates in LIMS2.
Required options:
- plate: Name of design plate to create
- user: Name of user creating the plate
- plate-data-file: file containing data about the crispr plate wells.

The plate data file is a csv file, with 2 columns:
- well_name
- crispr_id

The file must have these column headers.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use MooseX::Types::Path::Class;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Create Crispr Plate';
};

has plate => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'Name of crispr plate',
    required      => 1,
);

has species => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => 'Species these crispr sites target, currently only Mouse or Human is valid',
    traits        => [ 'Getopt' ],
);

has plate_data_file => (
    is            => 'ro',
    isa           => 'Path::Class::File',
    traits        => [ 'Getopt' ],
    documentation => 'File holding design plate data, 2 column, well_name and crispr_id',
    coerce        => 1,
    cmd_flag      => 'plate-data-file',
    required      => 1,
);

has appends => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'CRISPR appends type (u6, t7-barry, t7-wendy)',
    required      => 1,
);

has user => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'User who is creating the plate',
    required      => 1,
);

has crispr_plate_data => (
    is     => 'rw',
    isa    => 'HashRef',
    traits => [ 'NoGetopt' ],
);

has wge_crispr_ids => (
    is            => 'ro',
    isa           => 'Bool',
    traits        => [ 'Getopt' ],
    documentation => 'Plate data file contains WGE crispr IDs (these must have been imported into LIMS2)',
    default       => 0,
    cmd_flag      => 'wge-crispr-ids',
);

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info( 'Creating crispr plate: ' . $self->plate );

    $self->build_crispr_plate_data;

    $self->model->txn_do(
        sub {
            $self->model->create_plate( $self->crispr_plate_data );
            unless ( $self->commit ) {
                $self->model->txn_rollback;
            }
        }
    );

    return;
}

sub build_crispr_plate_data {
    my $self = shift;
    $self->log->info( 'Building crispr plate data' );
    my @wells;

    my $csv = Text::CSV->new();
    my $fh = $self->plate_data_file->openr or die( 'Can not open plate data file' );
    $csv->column_names( @{ $csv->getline( $fh ) } );

    while ( my $data = $csv->getline_hr( $fh ) ) {
        $self->log->debug( 'Process well data for: ' . $data->{well_name} );
        try{
            my $well_data = $self->_build_well_data( $data );
            push @wells, $well_data;
        }
        catch {
            $self->log->logdie('Error creating well data: ' . $_ );
        };
    }

    $self->crispr_plate_data(
        {
            name       => $self->plate,
            species    => $self->species,
            type       => 'CRISPR',
            appends    => $self->appends,
            created_by => $self->user,
            wells      => \@wells,
        }
    );

    return;
}

sub _build_well_data {
    my ( $self, $data ) = @_;

    my $crispr;
    if($self->wge_crispr_ids){
        $crispr = $self->model->retrieve_crispr( { wge_crispr_id => $data->{crispr_id} } );
    }
    else{
        $crispr = $self->model->retrieve_crispr( { id => $data->{crispr_id} } );
    }

    my %well_data;
    $well_data{well_name}    = $data->{well_name};
    $well_data{crispr_id}    = $crispr->id;
    $well_data{process_type} = 'create_crispr';

    return \%well_data;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
