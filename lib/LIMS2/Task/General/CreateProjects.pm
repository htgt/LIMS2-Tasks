package LIMS2::Task::General::CreateProjects;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CreateProjects::VERSION = '0.006';
}
## use critic

use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::CreateProjects - Create new LIMS2 projects

=head1 DESCRIPTION

This task creates new LIMS2 projects for a specified sponsor, from a list of MGI accession ids.
Input file is a simple text file, with a seperate mgi accession id on each line.

It first checks to see if that sponsor already has a project for that gene.
If not a new project is created, along with the project allele information.

The profile for the sponsor must be known before a new project can be created ( see the %PROFILES hash )

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
    Syboss        => 'homozygous',
    Pathogens     => 'homozygous',
    Core          => 'homozygous',
    'Cre Knockin' => 'cre_knockin',
);

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

has profile => (
    is         => 'ro',
    isa        => 'HashRef',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

sub _build_profile {
    my $self = shift;

    my $profile_type = $SPONSOR_PROFILE{ $self->sponsor };

    return $PROFILES{ $profile_type };
}

has first_allele_data => (
    is         => 'ro',
    isa        => 'HashRef',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

sub _build_first_allele_data {
    my $self = shift;

    my %allele_data;
    $allele_data{ allele_type } = 'first';
    $allele_data{ cassette_function } = $self->profile->{first}{cassette};
    $allele_data{ mutation_type } = $self->profile->{first}{mutation_type};

    return \%allele_data;
}

has second_allele_data => (
    is         => 'ro',
    isa        => 'HashRef',
    traits     => [ 'NoGetopt' ],
    lazy_build => 1,
);

sub _build_second_allele_data {
    my $self = shift;

    $self->log->logdie( 'Do not have second allele target, for sponsor' . $self->sponsor )
        unless exists $self->profile->{second};

    my %allele_data;
    $allele_data{ allele_type } = 'second';
    $allele_data{ cassette_function } = $self->profile->{second}{cassette};
    $allele_data{ mutation_type } = $self->profile->{second}{mutation_type};

    return \%allele_data;
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

Check a project for the given gene and sponsor does not already exist.

=cut
sub project_exists {
    my ( $self, $mgi_id ) = @_;

    my $project = $self->schema->resultset('Project')->find(
        {
            sponsor_id => $self->sponsor,
            gene_id    => $mgi_id,
        }
    );

    if ( $project ) {
        $self->log->debug( "Already have $mgi_id project for sponsor " . $self->sponsor );
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

    my $allele_request = $self->build_allele_request( $mgi_id );
    $self->log->debug( "Allele request: $allele_request" );

    my $project = $self->schema->resultset( 'Project' )->create(
        {
            sponsor_id     => $self->sponsor,
            gene_id        => $mgi_id,
            targeting_type => $self->profile->{targeting_type},
            allele_request => $allele_request,
        }
    );
    $self->log->debug( 'Created new project: ' . $project->id );

    $self->create_project_alleles( $project );
    return;
}

=head2 build_allele_request

Build the project allele_request json string.

=cut
sub build_allele_request {
    my ( $self, $mgi_id ) = @_;
    my %allele_request;

    $allele_request{gene_id} = $mgi_id;
    $allele_request{targeting_type} = $self->profile->{targeting_type};
    $allele_request{first_allele_cassette_function} = $self->profile->{first}{cassette};
    $allele_request{first_allele_mutation_type} = $self->profile->{first}{mutation_type};

    # add second allele information if project is double targeted
    if ( exists $self->profile->{second} ) {
        $allele_request{second_allele_cassette_function} = $self->profile->{second}{cassette};
        $allele_request{second_allele_mutation_type} = $self->profile->{second}{mutation_type};
    }

    return encode_json( \%allele_request );
}

=head2 create_project_alleles

Create project_alleles for a project.
Single targeted projects will have one first allele.
Dounble targeted projects will have a first and second allele.

=cut
sub create_project_alleles{
    my ( $self, $project ) = @_;

    # all projects will target a first allele
    $project->project_alleles->create( $self->first_allele_data );
    $self->log->debug( "Created first allele for project: " . $project->id );

    # create second allele if project is double targeted
    if ( exists $self->profile->{second} ) {
        $project->project_alleles->create( $self->second_allele_data );
        $self->log->debug( "Created second allele for project: " . $project->id );
    }

    return;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
