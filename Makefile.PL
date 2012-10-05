
use strict;
use warnings;



use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Script and task framework for LIMS2",
  "AUTHOR" => "Ray Miller <rm7\@sanger.ac.uk>",
  "BUILD_REQUIRES" => {
    "English" => 0,
    "File::Find" => 0,
    "File::Temp" => 0,
    "Test::More" => "0.88"
  },
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "LIMS2-Tasks",
  "EXE_FILES" => [
    "bin/lims2-task"
  ],
  "LICENSE" => "perl",
  "NAME" => "LIMS2::Tasks",
  "PREREQ_PM" => {
    "Const::Fast" => 0,
    "IPC::System::Simple" => 0,
    "LIMS2::Model" => 0,
    "LIMS2::Model::DBConnect" => 0,
    "LIMS2::Report" => 0,
    "LIMS2::Util::EnsEMBL" => 0,
    "LIMS2::Util::YAMLIterator" => 0,
    "List::MoreUtils" => 0,
    "Log::Log4perl" => 0,
    "Moose" => 0,
    "MooseX::App::Cmd" => 0,
    "MooseX::App::Cmd::Command" => 0,
    "MooseX::Log::Log4perl" => 0,
    "Parallel::ForkManager" => 0,
    "Try::Tiny" => 0,
    "namespace::autoclean" => 0,
    "strict" => 0,
    "warnings" => 0
  },
  "VERSION" => "0.003",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



