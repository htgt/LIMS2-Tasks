package LIMS2::Task::General::CreateProjects;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CreateProjects::VERSION = '0.015';
}
## use critic

use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::CreateProjects - Create new LIMS2 projects

=head1 DESCRIPTION

This task creates new LIMS2 projects for a specified sponsor and species, from a list of MGI accession ids.
Input file is a simple text file, with a seperate mgi accession id on each line. The file should be for a single sponsor and species, you cannot mix types.

It first checks to see if that sponsor already has a project for that gene and species.
If not a new project is created, along with the project allele information.

The profile for the sponsor must be known before a new project can be created ( see the %PROFILES hash )

The species for the project must be known before a new project can be created ( see the %SPECIES hash )

=cut

use Moose;
use Try::Tiny;
use Perl6::Slurp;
use Const::Fast;
use JSON qw( encode_json );
use MooseX::Types::Path::Class;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Create LIMS2 Projects';
};

const my $MGI_ACCESSION_ID_RX => qr/^MGI:\d+$/;

const my %SPONSOR_PROFILE => (
    'Syboss'               => 'homozygous',
    'Pathogens'            => 'homozygous',
    'Core'                 => 'homozygous',
    'Cre Knockin'          => 'cre_knockin',
    'EUCOMMTools Recovery' => 'ko_first',
#   'Cre Bac'       => 'cre_bac',
    'Barry Short Arm Recovery' => 'ko_first',
);

const my %SPECIES => (
    'Mouse'       => 'for mouse projects',
    'Human'       => 'for human projects',
);

# NB: The cassette and mutation_type information now resides in the
# targeting_profile_alleles table of LIMS2
#
# project_alleles are no longer needed
const my %PROFILES => (
    homozygous => {
        targeting_type => 'double_targeted',
        first => {
            cassette      => 'ko_first',
            mutation_type => 'ko_first',
        },
        second => {
            cassette      => 'reporter_only',
            mutation_type => 'ko_first',
        }
    },
    cre_knockin => {
        targeting_type => 'single_targeted',
        first => {
            cassette      => 'cre_knock_in',
            mutation_type => 'cre_knock_in',
        },
    },
    ko_first => {
        targeting_type => 'single_targeted',
        first => {
            cassette      => 'ko_first',
            mutation_type => 'ko_first',
        },
    },
);

has sponsor => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'Project sponsor',
    required      => 1,
    trigger       => \&_check_sponsor,
);

sub _check_sponsor {
    my ( $self, $sponsor ) = @_;

    unless ( exists $SPONSOR_PROFILE{ $sponsor } ) {
        die("Unknown sponsor $sponsor");
    }

    return;
}

has species => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'Species - Mouse or Human',
    required      => 1,
    trigger       => \&_check_species,
);

sub _check_species {
    my ( $self, $species ) = @_;

    unless ( exists $SPECIES{ $species } ) {
        die("Unknown species $species");
    }

    return;
}

has targeting_profile_id => (
    is         => 'ro',
    isa        => 'Str',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

sub _build_targeting_profile_id {
    my $self = shift;

    return $SPONSOR_PROFILE{ $self->sponsor };
}

has profile => (
    is         => 'ro',
    isa        => 'HashRef',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

sub _build_profile {
    my $self = shift;

    return $PROFILES{ $self->targeting_profile_id };
}


has project_genes_file => (
    is            => 'ro',
    isa           => 'Path::Class::File',
    traits        => [ 'Getopt' ],
    documentation => 'File holding mgi accession ids of genes being targeted',
    coerce        => 1,
    cmd_flag      => 'project-genes-file',
    required      => 1,
);

has mgi_accession_ids => (
    is         => 'rw',
    isa        => 'ArrayRef',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

## no critic(BuiltinFunctions::ProhibitComplexMappings)
sub _build_mgi_accession_ids {
    my $self = shift;
    my @mgi_genes;

    my @genes = map{ chomp; $_ } $self->project_genes_file->slurp;
    for my $gene ( @genes ) {
        if ( $gene =~ $MGI_ACCESSION_ID_RX ) {
            push @mgi_genes, $gene;
        }
        else {
            $self->log->warn("$gene is not a mgi accession id, skipping");
        }
    }

    return \@mgi_genes;
}
## use critic

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info( 'Creating projects for sponsor: ' . $self->sponsor );

    $self->model->txn_do(
        sub {
            try{
                $self->create_projects;
                unless ( $self->commit ) {
                    $self->log->info( 'Non commit mode, rolling back changes' );
                    $self->model->txn_rollback;
                }
            }
            catch {
                $self->log->error( 'Error when creating projects: ' . $_ );
                $self->model->txn_rollback;
            };
        }
    );

    return;
}

=head2 create_projects

Create the new projects from the given gene list.

=cut
sub create_projects {
    my $self = shift;

    for my $mgi_id ( @{ $self->mgi_accession_ids } ) {
        next if $self->project_exists( $mgi_id );
        $self->create_project( $mgi_id );
    }

    return;
}

=head2 project_exists

Check a project for the given gene, species and sponsor does not already exist.

=cut
sub project_exists {
    my ( $self, $mgi_id ) = @_;

    my $project = $self->schema->resultset('Project')->find(
        {
            gene_id    => $mgi_id,
            species_id => $self->species,
            targeting_type => $self->profile->{targeting_type},
            targeting_profile_id => $self->targeting_profile_id,
        }
    );

    if ( $project ) {
        $self->log->debug( "Already have a project for gene $mgi_id and targeting profile " . $self->targeting_profile_id );
        if(grep { $_ eq $self->sponsor } $project->sponsor_ids){
            $self->log->debug( "Project already belongs to sponsor " . $self->sponsor );
        }
        else{
            $self->model->add_project_sponsor({
                project_id => $project->id,
                sponsor_id => $self->sponsor,
            });
            $self->log->debug( "Added sponsor ". $self->sponsor ." to existing project");
        }
        return 1;
    }

    return;
}

=head2 create_project

Create a project for a given gene ( mgi accessions id ).

=cut
sub create_project {
    my ( $self, $mgi_id ) = @_;
    $self->log->info( "Creating project for $mgi_id, sponsor: " . $self->sponsor );

    my $project = $self->schema->resultset( 'Project' )->create(
        {
            gene_id        => $mgi_id,
            targeting_type => $self->profile->{targeting_type},
            species_id     => $self->species,
            targeting_profile_id => $self->targeting_profile_id,
        }
    );
    $self->model->add_project_sponsor({
        project_id => $project->id,
        sponsor_id => $self->sponsor,
    });
    $self->log->debug( 'Created new project: ' . $project->id );

    return;
}


__PACKAGE__->meta->make_immutable;

1;

__END__
