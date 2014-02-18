package LIMS2::Task::General::CreateDesignPlate;
use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::CreateDesignPlate

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
use LIMS2::Model::Util::BacsForDesign qw( bacs_for_design );
use MooseX::Types::Path::Class;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Create Design Plate';
};

has plate => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'Name of design plate',
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
    documentation => 'File holding design plate data, 2 column, well_name and design_id',
    coerce        => 1,
    cmd_flag      => 'plate-data-file',
    required      => 1,
);

has user => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'User who is creating the plate',
    required      => 1,
);

has design_plate_data => (
    is     => 'rw',
    isa    => 'HashRef',
    traits => [ 'NoGetopt' ],
);

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info( 'Creating design plate: ' . $self->plate );

    $self->build_design_plate_data;

    $self->model->txn_do(
        sub {
            $self->model->create_plate( $self->design_plate_data );
            unless ( $self->commit ) {
                $self->model->txn_rollback;
            }
        }
    );

    return;
}

sub build_design_plate_data {
    my $self = shift;
    $self->log->info( 'Building design plate data' );
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

    $self->design_plate_data(
        {
            name       => $self->plate,
            species    => $self->species,
            type       => 'DESIGN',
            created_by => $self->user,
            wells      => \@wells,
        }
    );

    return;
}

sub _build_well_data {
    my ( $self, $data ) = @_;

    my $design = $self->model->c_retrieve_design( { id => $data->{design_id} } );
    my $bac_data = $self->_build_bac_data( $design );

    my %well_data;
    $well_data{well_name}    = $data->{well_name};
    $well_data{design_id}    = $data->{design_id};
    $well_data{process_type} = 'create_di';
    $well_data{bacs}         =  $bac_data if $bac_data;

    return \%well_data;
}

sub _build_bac_data {
    my ( $self, $design ) = @_;
    my @bac_data;

    my $bacs = try{ bacs_for_design( $self->model, $design ) };

    unless( $bacs ) {
        $self->log->warn( 'Could not find bacs for design: ' . $design->id );
        return;
    }

    my $bac_plate = 'a';
    for my $bac ( @{ $bacs } ) {
        push @bac_data, {
            bac_plate   => $bac_plate++,
            bac_name    => $bac,
            bac_library => 'black6'
        };
    }

    return \@bac_data;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
