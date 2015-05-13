# LIMS2-Tasks
Command line script framework for LIMS2, built upon [Moosex::App::Cmd](https://metacpan.org/pod/MooseX::App::Cmd).
This module is a combination on [MooseX::Getopt](https://metacpan.org/pod/MooseX::Getopt) and [App::Cmd](https://metacpan.org/pod/App::Cmd), read these docs for more extensive details on how to use these modules.

## Benefits
* You only need to add one Moose module to create a new command line script.
* This new script automatically gets a number of useful command line options, helper methods and attributes.

### Default Command Line Options
* Logging is already setup through Log::Log4perl.
* Specify log level output:
    * --trace
    * --debug
    * --verbose
* Specify logging style with `--log-layout` option.
* Uses the `--commit` option to only persist data changes if this option is used.

### Default Attributes
* You have access to the LIMS2 database through the `schema` attribute.
* The LIMS2 model is available through the `model` attribute.
* You can use our EnsEMBL util module through the `ensembl_util` attribute.

## Basic Usage
* `lims2-task` command will list all the current commands available, along with a short description.
* Use `lims2-task` plus the command name to see options for that command e.g: `lims2-task create-projects`
* By default the task will wrap any data changes in a transaction and rollback unless the `--commit` option is set.

## Creating A New Task
* Add a new moose module to `LIMS2::Task::General` namespace.
* The name of the module will determine the command name, the framework with split capitalised words with dashes and lowercase everything:
    * e.g. LIMS2::Task::General::CleanReportCache becomes the `clean-report-cache` command.
* Take a look at the [LIMS2::Task::General::CleanReportCache](https://github.com/htgt/LIMS2-Tasks/blob/devel/lib/LIMS2/Task/General/CleanReportCache.pm) task for a very simple command line task you could use as a template.
* You must use the following command to start using the framework:

 ```
extends 'LIMS2::Task';
```
* You must provide a subroutine named `execute` to tell the framework what to do.
* Its good to provide details of what the script does like this:

```
override abstract => sub {
    'Short description of script here';
};
```

* Too add new command line options add a new moose attribute with the `Getopt` trait, e.g:

```
has user_name => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'User who is creating the plate',
    cmd_flag      => 'user',
    required      => 1,
);
```

* There are a few extra attribute options to note here:
    * `documentation` : automatically display this text when you run the cmd with the --help flag
    * `cmd_flag`: the name you want for the cmd line option ( otherwise defaults to attribute name )
* Wrap any data changes in a transaction, rollback changes unless the `commit` attribute is true.

## Creating New YAML Data Loader Task
* A special subclass of LIMS2::Task that loads data in a YAML format into a LIMS2 database.
* Add a new moose module to `LIMS2::Task::YAMLDataLoader` namespace.
* Input YAML file is sent in as command line argument.
* It has 2 extra command line options available by default:
    * `--continue-on-error` if one record fails to be created carry on trying to load the others ( true by default )
    * `--dump-fail-params` Dump out YAML of any records that failed to persist.
* Look at [LIMS2::Task::YAMLDataLoader::LoadDesigns](https://github.com/htgt/LIMS2-Tasks/blob/devel/lib/LIMS2/Task/YAMLDataLoader/LoadDesigns.pm) for a example of one of these scripts.
* You must override the `create` subroutine, this tells the script how to create the record in LIMS2.
* You should override the `record_key` subroutine, this tells the script what YAML variable in the record to
use when identifying the record ( e.g for a design it would be the design_id )
* You can optionally override the `wanted` subroutine, this will be a test carried out on the record data to check if we want to load it into LIMS2.
