package LIMS2::Task::General::CreateDesignPlate;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CreateDesignPlate::VERSION = '0.015';
}
## use critic

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

Optional flags:
- generate-primers: Generate primers for designs and all crisprs/pairs/groups linked to it
- internal-primers: Generate internal primers for crispr groups linked to designs (use in addition to generate-primers flag)

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
    documentation => 'Generate primers for design and any crisprs, pairs or groups linked to the designs',
    cmd_flag      => 'generate-primers',
    default       => 0,
);

has internal_primers => (
    is            => 'ro',
    isa           => 'Bool',
    traits        => ['Getopt'],
    documentation => 'Generate internal primers for any crispr groups linked to the designs (use with generate-primers option)',
    cmd_flag      => 'internal-primers',
    default       => 0,
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

    my $well_design_ids = {};

    while ( my $data = $csv->getline_hr( $fh ) ) {
        $self->log->debug( 'Process well data for: ' . $data->{well_name} );
        try{
            my $well_data = $self->_build_well_data( $data );
            $well_design_ids->{ $data->{well_name} } = $data->{design_id};
            push @wells, $well_data;
        }
        catch {
            $self->log->logdie('Error creating well data: ' . $_ );
        };
    }

    # Store well design and crispr IDs for primer generation
    $self->well_design_ids( $well_design_ids );

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
        run_on_farm         => 0,
    );

    # Set up QcPrimers util for genotyping
    my $design_primer_util = LIMS2::Util::QcPrimers->new({
        primer_project_name => 'design_genotyping',
        overwrite           => 0,
        %common_params,
    });

    # Set up QcPrimers util for crisprs
    my $crispr_seq_primer_util = LIMS2::Util::QcPrimers->new({
        primer_project_name => 'crispr_sequencing',
        overwrite           => 0,
        %common_params,
    });
    my @seq_primer_names = $crispr_seq_primer_util->primer_name_list;

    my $crispr_internal_primer_util = LIMS2::Util::QcPrimers->new({
        primer_project_name => 'mgp_recovery',
        overrwite           => 0,
        %common_params,
    });
    my @internal_primer_names = $crispr_internal_primer_util->primer_name_list;

    # Always overwrite the PCR primers if we have generated new sequencing primers
    my $crispr_pcr_primer_util = LIMS2::Util::QcPrimers->new({
        primer_project_name => 'crispr_pcr',
        overwrite            => 1,
        %common_params,
    });

    my @design_primer_names = $design_primer_util->primer_name_list;

    while ( my ($well_name, $design_id) = each %{ $self->well_design_ids} ){
        $self->log->info("==== Generating primers for well $well_name, design $design_id ====");
        my $design = $self->model->c_retrieve_design( { id => $design_id } );

        # generate design primers unless already exist
        my @existing_primers = $self->_existing_primers($design, \@design_primer_names);
        if(@existing_primers){
            $self->log->debug("Existing ".(join ", ", @existing_primers)." primers found for design: "
                             .$design->id.". Skipping primer generation");
        }
        else{
            $self->log->debug("Generating genotyping primers for design $design_id");
            $design_primer_util->design_genotyping_primers( $design );
        }

        my @crispr_collections;

        # All crisprs linked to design
        push @crispr_collections, grep { $_ } map { $_->crispr } $design->crispr_designs;
        # All crispr pairs linked to design
        push @crispr_collections, grep { $_ } map { $_->crispr_pair } $design->crispr_designs;

        # Decide how to handle crispr groups linked to design
        my @crispr_groups = grep { $_ } map { $_->crispr_group } $design->crispr_designs;
        unless( $self->internal_primers){
            # No internal primers needed so treat crispr groups in the same way as crisprs and pairs
            push @crispr_collections, @crispr_groups;
            @crispr_groups = ();
        }

        foreach my $collection (@crispr_collections){
            # skip if already has primers
            my $collection_string = $collection->id_column_name.": ".$collection->id;

            my @existing_crispr_primers = $self->_existing_primers($collection, \@seq_primer_names);
            if(@existing_crispr_primers){
                $self->log->debug("Existing ".(join ", ", @existing_crispr_primers)
                                 ." primers found for $collection_string. Skipping primer generation");
                next;
            }

            $self->log->debug("Generating crispr sequencing primers for $collection_string");
            my ($primer_data) = $crispr_seq_primer_util->crispr_sequencing_primers($collection);

            if($primer_data){
                $self->log->debug("Generating crispr PCR primers for $collection_string");
                $crispr_pcr_primer_util->crispr_PCR_primers($primer_data, $collection);
            }
        }

        foreach my $group (@crispr_groups){
            # skip if already has primers
            my $collection_string = "crispr_group_id: ".$group->id;
            my @existing_group_primers = $self->_existing_primers($group, \@internal_primer_names);
            if(@existing_group_primers){
                $self->log->debug("Existing ".(join ", ", @existing_group_primers)
                    ." primers found for $collection_string. Skipping primer generation");
                next;
            }

            $self->log->debug("Generating crispr group sequencing primers with internal primer for $collection_string");
            my ($primer_data) = $crispr_internal_primer_util->crispr_group_genotyping_primers($group);

            if($primer_data){
                $self->log->debug("Generating crispr PCR primers for $collection_string");
                $crispr_pcr_primer_util->crispr_PCR_primers($primer_data, $group);
            }
        }
    }

    return;
}

sub _existing_primers{
    my ($self, $object, $primer_name_list) = @_;

    my @existing_primers = grep { $_ } map { $object->current_primer($_) } @$primer_name_list;
    my @existing_names = map { $_->as_hash->{primer_name} }  @existing_primers;

    return @existing_names;
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
