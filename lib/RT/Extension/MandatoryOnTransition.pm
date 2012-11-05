use strict;
use warnings;
package RT::Extension::MandatoryOnTransition;

our $VERSION = '0.02';

=head1 NAME

RT-Extension-MandatoryOnTransition - Require core fields and ticket custom fields on status transitions

=head1 DESCRIPTION

This RT extension enforces that certain fields have values before tickets are
explicitly moved to or from specified statuses.  If you list custom fields
which must have a value before a ticket is resolved, those custom fields will
automatically show up on the "Resolve" page.  The reply/comment won't be
allowed until a value is provided.

See the configuration example under L</INSTALLATION>.

=head2 Supported fields

This extension only enforces mandatory-ness on defined status transitions.

=head3 Basics

Currently the following are supported:

=over 4

=item Content

Requires an update message (reply/comment text) before the transition.

=item TimeWorked

Requires the ticket has a non-zero amount of Time Worked recorded already B<or>
that time worked will be recorded with the current reply/comment in the Worked
field on the update page.

=item TimeTaken

Requires that the Worked field on the update page is non-zero.

=back

A larger set of basic fields may be supported in future releases.  If you'd
like to see additional fields added, please email your request to the bug
address at the bottom of this documentation.

=head3 Custom fields

Ticket custom fields of all types are supported.

=head1 CAVEATS

=head2 Custom field validation (I<Input must match [Mandatory]>)

The custom fields enforced by this extension are validated by the standard RT
rules.  If you've set Validation patterns for your custom fields, those will be
checked before mandatory-ness is checked.  B<< Setting a CFs Validation to
C<(?#Mandatory).> will not magically make it enforced by this extension. >>

=head2 Actions menu

This extension does B<not> affect "quick actions" (those without an update
type) configured in your lifecycle (and appearing in the ticket Actions menu).
If you're requiring fields on resolve, for example, and don't want folks to
have a "Quick Resolve" button that skips the required fields, adjust your
lifecycle config to provide an update type (i.e make it a non-quick action).
Quick actions may be supported in a future release.

=head1 INSTALLATION

=over

=item perl Makefile.PL

=item make

=item make install

May need root permissions

=item Enable and configure this extension

Add this line to </opt/rt4/etc/RT_SiteConfig.pm>:

    Set(@Plugins, qw(RT::Extension::MandatoryOnTransition));

or add C<RT::Extension::MandatoryOnTransition> to your existing C<@Plugins> line.

Then configure which fields should be mandatory on certain status changes
(either globally or in a specific queue) using the C<%MandatoryOnTransition>
config option.  This option takes the generic form of:

    Set( %MandatoryOnTransition,
        'QueueName' => {
            'from -> to' => [ 'BasicField', 'CF.MyField', ],
        },
    );

The fallback for queues without specific rules is specified with C<'*'> where
the queue name would normally be.

Below is an example which requires 1) time worked and filling in a custom field
named Resolution before resolving tickets in the Helpdesk queue and 2) a
Category selection before resolving tickets in every other queue.

    Set( %MandatoryOnTransition,
        Helpdesk => {
            '* -> resolved' => ['TimeWorked', 'CF.Resolution'],
        },
        '*' => {
            '* -> resolved' => 'CF.Category',
        },
    );

The transition syntax is similar to that found in RT's Lifecycles.  See
C<perldoc /opt/rt4/etc/RT_Config.pm>.

=item Clear your mason cache

    rm -rf /opt/rt4/var/mason_data/obj

=item Restart your webserver

=back

=head1 IMPLEMENTATION DETAILS

If you're just using this module on your own RT instance, you should stop
reading now.  You don't need to know about the implementation details unless
you're writing a patch against this extension.

=cut

$RT::Config::META{'MandatoryOnTransition'} = {
    Type            => 'HASH',
    PostLoadCheck   => sub {
        # Normalize field list to always be arrayref
        my $self = shift;
        my %config = $self->Get('MandatoryOnTransition');
        for my $transitions (values %config) {
            for (keys %$transitions) {
                next if ref $transitions->{$_} eq 'ARRAY';

                if (ref $transitions->{$_}) {
                    RT->Logger->error("%MandatoryOnTransition definition '$_' must be a single field name or an array ref of field names.  Ignoring.");
                    delete $transitions->{$_};
                    next;
                }

                $transitions->{$_} = [ $transitions->{$_} ];
            }
        }
        $self->Set(MandatoryOnTransition => %config);
    },
};

=head2 Package variables

=over 4

=item @CORE_SUPPORTED

The core (basic) fields supported by the extension.  Anything else configured
not in this list is stripped.

=item @CORE_TICKET

The core (basic) fields which should be called as methods on ticket objects to
check for current values.

=item %CORE_FOR_UPDATE

A mapping which translates core fields into their form input names.  For
example, Content is submitted as UpdateContent.

=back

If you're looking to add support for other core fields, you'll need to push
into @CORE_SUPPORTED and possibly @CORE_TICKET.  You may also need to add a
pair to %CORE_FOR_UPDATE.

=cut

our @CORE_SUPPORTED  = qw(Content TimeWorked TimeTaken);
our @CORE_TICKET     = qw(TimeWorked);
our %CORE_FOR_UPDATE = (
    TimeWorked  => 'UpdateTimeWorked',
    TimeTaken   => 'UpdateTimeWorked',
    Content     => 'UpdateContent',
);

=head2 Methods

=head3 RequiredFields

Returns two array refs of required fields for the described status transition.
The first is core fields, the second is CF names.  Returns empty array refs
on error or if nothing is required.

Takes a paramhash with the keys Ticket, Queue, From, and To.  Ticket should be
an object.  Queue should be a name.  From and To should be statuses.  If you
specify Ticket, only To is otherwise necessary.  If you omit Ticket, From, To,
and Queue are all necessary.

The first transition found in the order below is used:

    from -> to
    *    -> to
    from -> *

=cut

sub RequiredFields {
    my $self  = shift;
    my %args  = (
        Ticket  => undef,
        Queue   => undef,
        From    => undef,
        To      => undef,
        @_,
    );

    if ($args{Ticket}) {
        $args{Queue} ||= $args{Ticket}->QueueObj->Name;
        $args{From}  ||= $args{Ticket}->Status;
    }
    my ($from, $to) = @args{qw(From To)};
    return ([], []) unless $from and $to;

    my %config = $self->Config($args{Queue});
    return ([], []) unless %config;

    # No transition.
    return ([], []) if $from eq $to;

    my $required = $config{"$from -> $to"}
                || $config{"* -> $to"}
                || $config{"$from -> *"}
                || [];

    my %core_supported = map { $_ => 1 } @CORE_SUPPORTED;

    my @core = grep { !/^CF\./i && $core_supported{$_} } @$required;
    my @cfs  =  map { /^CF\.(.+)$/i; $1; }
               grep { /^CF\./i } @$required;

    return (\@core, \@cfs);
}

=head3 CheckMandatoryFields

Pulls core and custom mandatory fields from the configuration and
checks that they have a value set before transitioning to the
requested status.

Accepts a paramhash of values:
    ARGSRef => Reference to Mason ARGS
    Ticket => ticket object being updated
    Queue  => Queue object for the queue in which a new ticket is being created
    From   => Ticket status transitioning from
    To     => Ticket status transitioning to

Works for both create, where no ticket exists yet, and update on an
existing ticket. ARGSRef is required for both.

For create, you must also pass Queue, From, and To.

Update requires only Ticket and To since From can be fetched from the
ticket object.

=cut

sub CheckMandatoryFields {
    my $self = shift;
    my %args  = (
        Ticket  => undef,
        Queue   => undef,
        From    => undef,
        To      => undef,
        @_,
    );
    my $ARGSRef = $args{'ARGSRef'};

    my @errors;

    my ($core, $cfs) = $self->RequiredFields(
        Ticket  => $args{'Ticket'},
        Queue   => $args{'Queue'} ? $args{'Queue'}->Name : undef,
        From    => $args{'From'},
        To      => $args{'To'},
    );

    return \@errors unless @$core or @$cfs;

    # Check core fields, after canonicalization for update
    for my $field (@$core) {
        # Will we have a value on update?
        # If we have a Ticket, it's an update, so use the CORE_FOR_UPDATE values
        # otherwise it's a create so use raw field value with no UPDATE prefix
        my $arg = $args{'Ticket'} ? $CORE_FOR_UPDATE{$field} || $field
                                  : $field;
        next if defined $ARGSRef->{$arg} and length $ARGSRef->{$arg};

        # Do we have a value currently?
        # In Create the ticket hasn't been created yet.
        next if grep { $_ eq $field } @CORE_TICKET
          and ($args{'Ticket'} && $args{'Ticket'}->$field());

        (my $label = $field) =~ s/(?<=[a-z])(?=[A-Z])/ /g; # /
        push @errors,
          HTML::Mason::Commands::loc("[_1] is required when changing Status to [_2]",
                                     $label, $ARGSRef->{Status});
    }

    # Find the CFs we want
    my $CFs = $args{'Ticket'} ? $args{'Ticket'}->CustomFields
      : $args{'Queue'}->TicketCustomFields();

    if ( not $CFs ){
        $RT::Logger->error("Custom Fields object required to process mandatory custom fields");
        return \@errors;
    }

    $CFs->Limit( FIELD => 'Name', VALUE => $_, SUBCLAUSE => 'names', ENTRYAGGREGRATOR => 'OR' )
      for @$cfs;

    # For constructing NamePrefix for both update and create
    my $TicketId = $args{'Ticket'} ? $args{'Ticket'}->Id : '';

    # Validate them
    my $ValidCFs = $HTML::Mason::Commands::m->comp(
                            '/Elements/ValidateCustomFields',
                            CustomFields => $CFs,
                            NamePrefix => "Object-RT::Ticket-".$TicketId."-CustomField-",
                            ARGSRef => $ARGSRef
                           );

    # Check validation results and mandatory-ness
    while (my $cf = $CFs->Next) {
        # Is there a validation error?
        if ( not $ValidCFs
             and my $msg = $HTML::Mason::Commands::m->notes('InvalidField-' . $cf->Id)) {
            push @errors, loc($cf->Name) . ': ' . $msg;
            next;
        }

        # Do we have a submitted value for update?
        my $arg   = "Object-RT::Ticket-".$TicketId."-CustomField-".$cf->Id."-Value";
        my $value = ($ARGSRef->{"${arg}s-Magic"} and exists $ARGSRef->{"${arg}s"})
          ? $ARGSRef->{$arg . "s"}
            : $ARGSRef->{$arg};

        next if defined $value and length $value;

        # Is there a current value?  (Particularly important for Date/Datetime CFs
        # since they don't submit a value on update.)
        next if $args{'Ticket'} && $cf->ValuesForObject($args{'Ticket'})->Count;

        push @errors,
          HTML::Mason::Commands::loc("[_1] is required when changing Status to [_2]",
                                     $cf->Name, $ARGSRef->{Status});
    }

    return \@errors;
}

=head3 Config

Takes a queue name.  Returns a hashref for the given queue (possibly using the
fallback rules) which contains keys of transitions and values of arrayrefs of
fields.

You shouldn't need to use this directly.

=cut

sub Config {
    my $self  = shift;
    my $queue = shift || '*';
    my %config = RT->Config->Get('MandatoryOnTransition');
    return %{$config{$queue}} if $config{$queue};
    return %{$config{'*'}} if $config{'*'};
    return;
}

=head1 TODO

=over 4

=item Enforcement on Create

Configuration syntax is tricky and goes hand in hand with functionality here.

Do we allow separate field lists for on create, or re-use existing status
transition syntax?  That is, does C<< * -> resolved >> mean "a newly created
resolved ticket" too?

Components affected:

    index.html / QuickCreate
    Create.html
    SelfService
    Mobile

=item Enforcement on other update pages

    SelfService - can't do it without patches to <form> POST + additional callbacks
    Basics      - need to patch callback for skipping (at least)
    Jumbo       - need to patch callback for skipping (at least)
    Mobile      - n/a; doesn't show CFs on reply/update

=back

=head1 BUGS

All bugs should be reported via
L<http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Extension-MandatoryOnTransition>
or L<bug-RT-Extension-MandatoryOnTransition@rt.cpan.org>.

=head1 AUTHOR

Thomas Sibley <trs@bestpractical.com>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2012 by Best Practical Solutions

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

1;
