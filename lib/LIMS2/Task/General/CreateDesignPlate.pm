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
- A 3rd column containing cripsr_id, crispr_pair_id or crispr_group_id can be added

The file must have these column headers.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use LIMS2::Model::Util::BacsForDesign qw( bacs_for_design );
use MooseX::Types::Path::Class;
use namespace::autoclean;
use Data::UUID;
use Path::Class;
use LIMS2::Util::QcPrimers;
use Data::Dumper;

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

has generate_primers => (
    is            => 'ro',
    isa           => 'Bool',
    traits        => ['Getopt'],
    documentation => 'Generate primers for design and crisprs, pairs or groups included in plate-data-file',
    cmd_flag      => 'generate-primers',
    lazy_build    => 1,
);

has no_bacs => (
    is            => 'ro',
    isa           => 'Bool',
    traits        => ['Getopt'],
    documentation => 'No bacs for design',
    cmd_flag      => 'no-bacs',
    lazy_build    => 1,
);

sub _build_no_bacs {
    my $self = shift;

    if ( $self->species eq 'Human' ) {
        return 1;
    }

    return 0;
}

has design_plate_data => (
    is     => 'rw',
    isa    => 'HashRef',
    traits => [ 'NoGetopt' ],
);

has well_design_ids => (
    is     => 'rw',
    isa    => 'HashRef',
    traits => [ 'NoGetopt' ],
);

has crispr_column => (
    is     => 'rw',
    isa    => 'Str',
    traits => [ 'NoGetopt' ],
);

has well_crispr_ids => (
    is     => 'rw',
    isa    => 'HashRef',
    traits => [ 'NoGetopt' ],
);

has job_id => (
    is    => 'ro',
    isa   => 'Str',
    lazy_build => 1,
    traits => [ 'NoGetopt' ],
);

sub _build_job_id {
    return Data::UUID->new->create_str();
};

has base_dir => (
    is     => 'ro',
    isa    => 'Str',
    lazy_build => 1,
    traits => [ 'NoGetopt' ],
);

sub _build_base_dir {
    my $self = shift;
    $ENV{LIMS2_PRIMER_DIR} or die "LIMS2_PRIMER_DIR environment variable not set";
    my $primer_dir = dir( $ENV{LIMS2_PRIMER_DIR} );
    my $base_dir = $primer_dir->subdir( $self->job_id );
    $base_dir->mkpath;
    return "$base_dir";
}

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

    if($self->generate_primers){
        $self->run_primer_generation();
    }

    return;
}

sub build_design_plate_data {
    my $self = shift;
    $self->log->info( 'Building design plate data' );
    my @wells;

    my $csv = Text::CSV->new();
    my $fh = $self->plate_data_file->openr or die( 'Can not open plate data file' );
    $csv->column_names( @{ $csv->getline( $fh ) } );

    my ($crispr_column) = grep { $_=~/crispr/ } $csv->column_names();
    if($crispr_column){
        $self->crispr_column( $crispr_column );
    }

    my $well_crispr_ids = {};
    my $well_design_ids = {};

    while ( my $data = $csv->getline_hr( $fh ) ) {
        $self->log->debug( 'Process well data for: ' . $data->{well_name} );
        try{
            my $well_data = $self->_build_well_data( $data );
            $well_design_ids->{ $data->{well_name} } = $data->{design_id};
            push @wells, $well_data;

            if($data->{$crispr_column}){
                $well_crispr_ids->{ $data->{well_name} } = $data->{$crispr_column};
            }
        }
        catch {
            $self->log->logdie('Error creating well data: ' . $_ );
        };
    }

    # Store well design and crispr IDs for primer generation
    $self->well_design_ids( $well_design_ids );
    $self->well_crispr_ids( $well_crispr_ids );

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

sub run_primer_generation {
    my ( $self ) = @_;

    $self->log->info("Generating primers for new plate");

    my %common_params = (
        model               => $self->model,
        base_dir            => $self->base_dir,
        persist_primers     => $self->commit,
        overwrite           => 0,
        run_on_farm         => 0,
    );

    # Set up QcPrimers util for genotyping
    my $design_primer_util = LIMS2::Util::QcPrimers->new({
        primer_project_name => 'design_genotyping',
        %common_params,
    });

    while ( my ($well_name, $design_id) = each %{ $self->well_design_ids} ){

        $self->log->debug("Generating design primers for well $well_name, design $design_id");
        # generate design primers
        try{
            my $design = $self->model->c_retrieve_design( { id => $design_id } );
            my ($primer_data, $seq, $db_primers) = $design_primer_util->design_genotyping_primers( $design );
        }
        catch{
            $self->log->warn("Primer generation failed for well $well_name, design $design_id - $_");
        };
    }

    if($self->crispr_column){
        # Set up QcPrimers util for crisprs
        my $crispr_seq_primer_util = LIMS2::Util::QcPrimers->new({
            primer_project_name => 'crispr_sequencing',
            %common_params,
        });

        my $crispr_pcr_primer_util = LIMS2::Util::QcPrimers->new({
            primer_project_name => 'crispr_pcr',
            %common_params,
        });

        while ( my ($well_name, $crispr_id) = each %{ $self->well_crispr_ids} ){
            # generate crispr seq and pcr primers
            my $crispr = $self->model->retrieve_crispr_collection({ $self->crispr_column => $crispr_id });
            my $primer_data;
            $self->log->debug("Generating crispr sequencing primers for well $well_name,".$self->crispr_column." $crispr_id");
            ($primer_data) = $crispr_seq_primer_util->crispr_sequencing_primers($crispr);

            if($primer_data){
                $self->log->debug("Generating crispr PCR primers for well $well_name");
                $crispr_pcr_primer_util->crispr_PCR_primers($primer_data, $crispr);
            }
        }
    }
}

sub _build_well_data {
    my ( $self, $data ) = @_;

    my $design = $self->model->c_retrieve_design( { id => $data->{design_id} } );

    my %well_data;
    $well_data{well_name}    = $data->{well_name};
    $well_data{design_id}    = $data->{design_id};
    $well_data{process_type} = 'create_di';

    unless ( $self->no_bacs ) {
        my $bac_data = $self->_build_bac_data( $design );
        $well_data{bacs} = $bac_data if $bac_data;
    }

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
