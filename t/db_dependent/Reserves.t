#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 62;
use Test::MockModule;
use Test::Warn;

use t::lib::Mocks;
use t::lib::TestBuilder;

use MARC::Record;
use DateTime::Duration;

use C4::Circulation;
use C4::Items;
use C4::Biblio;
use C4::Members;
use C4::Reserves;
use Koha::Caches;
use Koha::DateUtils;
use Koha::Holds;
use Koha::Items;
use Koha::Libraries;
use Koha::Notice::Templates;
use Koha::Patrons;
use Koha::Patron::Categories;
use Koha::CirculationRules;

BEGIN {
    require_ok('C4::Reserves');
}

# Start transaction
my $database = Koha::Database->new();
my $schema = $database->schema();
$schema->storage->txn_begin();
my $dbh = C4::Context->dbh;
$dbh->do('DELETE FROM circulation_rules');

my $builder = t::lib::TestBuilder->new;

my $frameworkcode = q//;


t::lib::Mocks::mock_preference('ReservesNeedReturns', 1);

# Somewhat arbitrary field chosen for age restriction unit tests. Must be added to db before the framework is cached
$dbh->do("update marc_subfield_structure set kohafield='biblioitems.agerestriction' where tagfield='521' and tagsubfield='a' and frameworkcode=?", undef, $frameworkcode);
my $cache = Koha::Caches->get_instance;
$cache->clear_from_cache("MarcStructure-0-$frameworkcode");
$cache->clear_from_cache("MarcStructure-1-$frameworkcode");
$cache->clear_from_cache("default_value_for_mod_marc-");
$cache->clear_from_cache("MarcSubfieldStructure-$frameworkcode");

## Setup Test
# Add branches
my $branch_1 = $builder->build({ source => 'Branch' })->{ branchcode };
my $branch_2 = $builder->build({ source => 'Branch' })->{ branchcode };
my $branch_3 = $builder->build({ source => 'Branch' })->{ branchcode };
# Add categories
my $category_1 = $builder->build({ source => 'Category' })->{ categorycode };
my $category_2 = $builder->build({ source => 'Category' })->{ categorycode };
# Add an item type
my $itemtype = $builder->build(
    { source => 'Itemtype', value => { notforloan => undef } } )->{itemtype};

t::lib::Mocks::mock_userenv({ branchcode => $branch_1 });

my $bibnum = $builder->build_sample_biblio({frameworkcode => $frameworkcode})->biblionumber;

# Create a helper item instance for testing
my ( $item_bibnum, $item_bibitemnum, $itemnumber ) = AddItem(
    {   homebranch    => $branch_1,
        holdingbranch => $branch_1,
        itype         => $itemtype
    },
    $bibnum
);

my $biblio_with_no_item = $builder->build({
    source => 'Biblio'
});


# Modify item; setting barcode.
my $testbarcode = '97531';
ModItem({ barcode => $testbarcode }, $bibnum, $itemnumber);

# Create a borrower
my %data = (
    firstname =>  'my firstname',
    surname => 'my surname',
    categorycode => $category_1,
    branchcode => $branch_1,
);
Koha::Patron::Categories->find($category_1)->set({ enrolmentfee => 0})->store;
my $borrowernumber = Koha::Patron->new(\%data)->store->borrowernumber;
my $patron = Koha::Patrons->find( $borrowernumber );
my $borrower = $patron->unblessed;
my $biblionumber   = $bibnum;
my $barcode        = $testbarcode;

my $bibitems       = '';
my $priority       = '1';
my $resdate        = undef;
my $expdate        = undef;
my $notes          = '';
my $checkitem      = undef;
my $found          = undef;

my $branchcode = Koha::Libraries->search->next->branchcode;

AddReserve($branchcode,    $borrowernumber, $biblionumber,
        $bibitems,  $priority, $resdate, $expdate, $notes,
        'a title',      $checkitem, $found);

my ($status, $reserve, $all_reserves) = CheckReserves($itemnumber, $barcode);

is($status, "Reserved", "CheckReserves Test 1");

ok(exists($reserve->{reserve_id}), 'CheckReserves() include reserve_id in its response');

($status, $reserve, $all_reserves) = CheckReserves($itemnumber);
is($status, "Reserved", "CheckReserves Test 2");

($status, $reserve, $all_reserves) = CheckReserves(undef, $barcode);
is($status, "Reserved", "CheckReserves Test 3");

my $ReservesControlBranch = C4::Context->preference('ReservesControlBranch');
t::lib::Mocks::mock_preference( 'ReservesControlBranch', 'ItemHomeLibrary' );
ok(
    'ItemHomeLib' eq GetReservesControlBranch(
        { homebranch => 'ItemHomeLib' },
        { branchcode => 'PatronHomeLib' }
    ), "GetReservesControlBranch returns item home branch when set to ItemHomeLibrary"
);
t::lib::Mocks::mock_preference( 'ReservesControlBranch', 'PatronLibrary' );
ok(
    'PatronHomeLib' eq GetReservesControlBranch(
        { homebranch => 'ItemHomeLib' },
        { branchcode => 'PatronHomeLib' }
    ), "GetReservesControlBranch returns patron home branch when set to PatronLibrary"
);
t::lib::Mocks::mock_preference( 'ReservesControlBranch', $ReservesControlBranch );

###
### Regression test for bug 10272
###
my %requesters = ();
$requesters{$branch_1} = Koha::Patron->new({
    branchcode   => $branch_1,
    categorycode => $category_2,
    surname      => "borrower from $branch_1",
})->store->borrowernumber;
for my $i ( 2 .. 5 ) {
    $requesters{"CPL$i"} = Koha::Patron->new({
        branchcode   => $branch_1,
        categorycode => $category_2,
        surname      => "borrower $i from $branch_1",
    })->store->borrowernumber;
}
$requesters{$branch_2} = Koha::Patron->new({
    branchcode   => $branch_2,
    categorycode => $category_2,
    surname      => "borrower from $branch_2",
})->store->borrowernumber;
$requesters{$branch_3} = Koha::Patron->new({
    branchcode   => $branch_3,
    categorycode => $category_2,
    surname      => "borrower from $branch_3",
})->store->borrowernumber;

# Configure rules so that $branch_1 allows only $branch_1 patrons
# to request its items, while $branch_2 will allow its items
# to fill holds from anywhere.

$dbh->do('DELETE FROM issuingrules');
$dbh->do(
    q{INSERT INTO issuingrules (categorycode, branchcode, itemtype, reservesallowed)
      VALUES (?, ?, ?, ?)},
    {},
    '*', '*', '*', 25
);

# CPL allows only its own patrons to request its items
Koha::CirculationRules->set_rules(
    {
        branchcode   => $branch_1,
        categorycode => undef,
        itemtype     => undef,
        rules        => {
            holdallowed  => 1,
            returnbranch => 'homebranch',
        }
    }
);

# ... while FPL allows anybody to request its items
Koha::CirculationRules->set_rules(
    {
        branchcode   => $branch_2,
        categorycode => undef,
        itemtype     => undef,
        rules        => {
            holdallowed  => 2,
            returnbranch => 'homebranch',
        }
    }
);

my $bibnum2 = $builder->build_sample_biblio({frameworkcode => $frameworkcode})->biblionumber;

my ($itemnum_cpl, $itemnum_fpl);
( undef, undef, $itemnum_cpl ) = AddItem(
    {   homebranch    => $branch_1,
        holdingbranch => $branch_1,
        barcode       => 'bug10272_CPL',
        itype         => $itemtype
    },
    $bibnum2
);
( undef, undef, $itemnum_fpl ) = AddItem(
    {   homebranch    => $branch_2,
        holdingbranch => $branch_2,
        barcode       => 'bug10272_FPL',
        itype         => $itemtype
    },
    $bibnum2
);


# Ensure that priorities are numbered correcly when a hold is moved to waiting
# (bug 11947)
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum2));
AddReserve($branch_3,  $requesters{$branch_3}, $bibnum2,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
AddReserve($branch_2,  $requesters{$branch_2}, $bibnum2,
           $bibitems,  2, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum2,
           $bibitems,  3, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
ModReserveAffect($itemnum_cpl, $requesters{$branch_3}, 0);

# Now it should have different priorities.
my $biblio = Koha::Biblios->find( $bibnum2 );
my $holds = $biblio->holds({}, { order_by => 'reserve_id' });;
is($holds->next->priority, 0, 'Item is correctly waiting');
is($holds->next->priority, 1, 'Item is correctly priority 1');
is($holds->next->priority, 2, 'Item is correctly priority 2');

my @reserves = Koha::Holds->search({ borrowernumber => $requesters{$branch_3} })->waiting();
is( @reserves, 1, 'GetWaiting got only the waiting reserve' );
is( $reserves[0]->borrowernumber(), $requesters{$branch_3}, 'GetWaiting got the reserve for the correct borrower' );


$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum2));
AddReserve($branch_3,  $requesters{$branch_3}, $bibnum2,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
AddReserve($branch_2,  $requesters{$branch_2}, $bibnum2,
           $bibitems,  2, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum2,
           $bibitems,  3, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);

# Ensure that the item's home library controls hold policy lookup
t::lib::Mocks::mock_preference( 'ReservesControlBranch', 'ItemHomeLibrary' );

my $messages;
# Return the CPL item at FPL.  The hold that should be triggered is
# the one placed by the CPL patron, as the other two patron's hold
# requests cannot be filled by that item per policy.
(undef, $messages, undef, undef) = AddReturn('bug10272_CPL', $branch_2);
is( $messages->{ResFound}->{borrowernumber},
    $requesters{$branch_1},
    'restrictive library\'s items only fill requests by own patrons (bug 10272)');

# Return the FPL item at FPL.  The hold that should be triggered is
# the one placed by the RPL patron, as that patron is first in line
# and RPL imposes no restrictions on whose holds its items can fill.

# Ensure that the preference 'LocalHoldsPriority' is not set (Bug 15244):
t::lib::Mocks::mock_preference( 'LocalHoldsPriority', '' );

(undef, $messages, undef, undef) = AddReturn('bug10272_FPL', $branch_2);
is( $messages->{ResFound}->{borrowernumber},
    $requesters{$branch_3},
    'for generous library, its items fill first hold request in line (bug 10272)');

$biblio = Koha::Biblios->find( $biblionumber );
$holds = $biblio->holds;
is($holds->count, 1, "Only one reserves for this biblio");
my $reserve_id = $holds->next->reserve_id;

# Tests for bug 9761 (ConfirmFutureHolds): new CheckReserves lookahead parameter, and corresponding change in AddReturn
# Note that CheckReserve uses its lookahead parameter and does not check ConfirmFutureHolds pref (it should be passed if needed like AddReturn does)
# Test 9761a: Add a reserve without date, CheckReserve should return it
$resdate= undef; #defaults to today in AddReserve
$expdate= undef; #no expdate
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
($status)=CheckReserves($itemnumber,undef,undef);
is( $status, 'Reserved', 'CheckReserves returns reserve without lookahead');
($status)=CheckReserves($itemnumber,undef,7);
is( $status, 'Reserved', 'CheckReserves also returns reserve with lookahead');

# Test 9761b: Add a reserve with future date, CheckReserve should not return it
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
t::lib::Mocks::mock_preference('AllowHoldDateInFuture', 1);
$resdate= dt_from_string();
$resdate->add_duration(DateTime::Duration->new(days => 4));
$resdate=output_pref($resdate);
$expdate= undef; #no expdate
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
($status)=CheckReserves($itemnumber,undef,undef);
is( $status, '', 'CheckReserves returns no future reserve without lookahead');

# Test 9761c: Add a reserve with future date, CheckReserve should return it if lookahead is high enough
($status)=CheckReserves($itemnumber,undef,3);
is( $status, '', 'CheckReserves returns no future reserve with insufficient lookahead');
($status)=CheckReserves($itemnumber,undef,4);
is( $status, 'Reserved', 'CheckReserves returns future reserve with sufficient lookahead');

# Test 9761d: Check ResFound message of AddReturn for future hold
# Note that AddReturn is in Circulation.pm, but this test really pertains to reserves; AddReturn uses the ConfirmFutureHolds pref when calling CheckReserves
# In this test we do not need an issued item; it is just a 'checkin'
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 0);
(my $doreturn, $messages)= AddReturn('97531',$branch_1);
is($messages->{ResFound}//'', '', 'AddReturn does not care about future reserve when ConfirmFutureHolds is off');
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 3);
($doreturn, $messages)= AddReturn('97531',$branch_1);
is(exists $messages->{ResFound}?1:0, 0, 'AddReturn ignores future reserve beyond ConfirmFutureHolds days');
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 7);
($doreturn, $messages)= AddReturn('97531',$branch_1);
is(exists $messages->{ResFound}?1:0, 1, 'AddReturn considers future reserve within ConfirmFutureHolds days');

# End of tests for bug 9761 (ConfirmFutureHolds)

# test marking a hold as captured
my $hold_notice_count = count_hold_print_messages();
ModReserveAffect($itemnumber, $requesters{$branch_1}, 0);
my $new_count = count_hold_print_messages();
is($new_count, $hold_notice_count + 1, 'patron notified when item set to waiting');

# test that duplicate notices aren't generated
ModReserveAffect($itemnumber, $requesters{$branch_1}, 0);
$new_count = count_hold_print_messages();
is($new_count, $hold_notice_count + 1, 'patron not notified a second time (bug 11445)');

# avoiding the not_same_branch error
t::lib::Mocks::mock_preference('IndependentBranches', 0);
is(
    DelItemCheck( $bibnum, $itemnumber),
    'book_reserved',
    'item that is captured to fill a hold cannot be deleted',
);

my $letter = ReserveSlip( { branchcode => $branch_1, borrowernumber => $requesters{$branch_1}, biblionumber => $bibnum } );
ok(defined($letter), 'can successfully generate hold slip (bug 10949)');

# Tests for bug 9788: Does Koha::Item->current_holds return a future wait?
# 9788a: current_holds does not return future next available hold
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 2);
t::lib::Mocks::mock_preference('AllowHoldDateInFuture', 1);
$resdate= dt_from_string();
$resdate->add_duration(DateTime::Duration->new(days => 2));
$resdate=output_pref($resdate);
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
my $item = Koha::Items->find( $itemnumber );
$holds = $item->current_holds;
my $dtf = Koha::Database->new->schema->storage->datetime_parser;
my $future_holds = $holds->search({ reservedate => { '>' => $dtf->format_date( dt_from_string ) } } );
is( $future_holds->count, 0, 'current_holds does not return a future next available hold');
# 9788b: current_holds does not return future item level hold
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum,
           $bibitems,  1, $resdate, $expdate, $notes,
           'a title',      $itemnumber, $found); #item level hold
$future_holds = $holds->search({ reservedate => { '>' => $dtf->format_date( dt_from_string ) } } );
is( $future_holds->count, 0, 'current_holds does not return a future item level hold' );
# 9788c: current_holds returns future wait (confirmed future hold)
ModReserveAffect( $itemnumber,  $requesters{$branch_1} , 0); #confirm hold
$future_holds = $holds->search({ reservedate => { '>' => $dtf->format_date( dt_from_string ) } } );
is( $future_holds->count, 1, 'current_holds returns a future wait (confirmed future hold)' );
# End of tests for bug 9788

$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
# Tests for CalculatePriority (bug 8918)
my $p = C4::Reserves::CalculatePriority($bibnum2);
is($p, 4, 'CalculatePriority should now return priority 4');
$resdate=undef;
AddReserve($branch_1,  $requesters{'CPL2'}, $bibnum2,
           $bibitems,  $p, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
$p = C4::Reserves::CalculatePriority($bibnum2);
is($p, 5, 'CalculatePriority should now return priority 5');
#some tests on bibnum
$dbh->do("DELETE FROM reserves WHERE biblionumber=?",undef,($bibnum));
$p = C4::Reserves::CalculatePriority($bibnum);
is($p, 1, 'CalculatePriority should now return priority 1');
#add a new reserve and confirm it to waiting
AddReserve($branch_1,  $requesters{$branch_1}, $bibnum,
           $bibitems,  $p, $resdate, $expdate, $notes,
           'a title',      $itemnumber, $found);
$p = C4::Reserves::CalculatePriority($bibnum);
is($p, 2, 'CalculatePriority should now return priority 2');
ModReserveAffect( $itemnumber,  $requesters{$branch_1} , 0);
$p = C4::Reserves::CalculatePriority($bibnum);
is($p, 1, 'CalculatePriority should now return priority 1');
#add another biblio hold, no resdate
AddReserve($branch_1,  $requesters{'CPL2'}, $bibnum,
           $bibitems,  $p, $resdate, $expdate, $notes,
           'a title',      $checkitem, $found);
$p = C4::Reserves::CalculatePriority($bibnum);
is($p, 2, 'CalculatePriority should now return priority 2');
#add another future hold
t::lib::Mocks::mock_preference('AllowHoldDateInFuture', 1);
$resdate= dt_from_string();
$resdate->add_duration(DateTime::Duration->new(days => 1));
AddReserve($branch_1,  $requesters{'CPL3'}, $bibnum,
           $bibitems,  $p, output_pref($resdate), $expdate, $notes,
           'a title',      $checkitem, $found);
$p = C4::Reserves::CalculatePriority($bibnum);
is($p, 2, 'CalculatePriority should now still return priority 2');
#calc priority with future resdate
$p = C4::Reserves::CalculatePriority($bibnum, $resdate);
is($p, 3, 'CalculatePriority should now return priority 3');
# End of tests for bug 8918

# Tests for cancel reserves by users from OPAC.
$dbh->do('DELETE FROM reserves', undef, ($bibnum));
AddReserve($branch_1,  $requesters{$branch_1}, $item_bibnum,
           $bibitems,  1, undef, $expdate, $notes,
           'a title',      $checkitem, '');
my (undef, $canres, undef) = CheckReserves($itemnumber);

is( CanReserveBeCanceledFromOpac(), undef,
    'CanReserveBeCanceledFromOpac should return undef if called without any parameter'
);
is(
    CanReserveBeCanceledFromOpac( $canres->{resserve_id} ),
    undef,
    'CanReserveBeCanceledFromOpac should return undef if called without the reserve_id'
);
is(
    CanReserveBeCanceledFromOpac( undef, $requesters{CPL} ),
    undef,
    'CanReserveBeCanceledFromOpac should return undef if called without borrowernumber'
);

my $cancancel = CanReserveBeCanceledFromOpac($canres->{reserve_id}, $requesters{$branch_1});
is($cancancel, 1, 'Can user cancel its own reserve');

$cancancel = CanReserveBeCanceledFromOpac($canres->{reserve_id}, $requesters{$branch_2});
is($cancancel, 0, 'Other user cant cancel reserve');

ModReserveAffect($itemnumber, $requesters{$branch_1}, 1);
$cancancel = CanReserveBeCanceledFromOpac($canres->{reserve_id}, $requesters{$branch_1});
is($cancancel, 0, 'Reserve in transfer status cant be canceled');

$dbh->do('DELETE FROM reserves', undef, ($bibnum));
AddReserve($branch_1,  $requesters{$branch_1}, $item_bibnum,
           $bibitems,  1, undef, $expdate, $notes,
           'a title',      $checkitem, '');
(undef, $canres, undef) = CheckReserves($itemnumber);

ModReserveAffect($itemnumber, $requesters{$branch_1}, 0);
$cancancel = CanReserveBeCanceledFromOpac($canres->{reserve_id}, $requesters{$branch_1});
is($cancancel, 0, 'Reserve in waiting status cant be canceled');

# End of tests for bug 12876

       ####
####### Testing Bug 13113 - Prevent juvenile/children from reserving ageRestricted material >>>
       ####

t::lib::Mocks::mock_preference( 'AgeRestrictionMarker', 'FSK|PEGI|Age|K' );

#Reserving an not-agerestricted Biblio by a Borrower with no dateofbirth is tested previously.

#Set the ageRestriction for the Biblio
my $record = GetMarcBiblio({ biblionumber =>  $bibnum });
my ( $ageres_tagid, $ageres_subfieldid ) = GetMarcFromKohaField( "biblioitems.agerestriction" );
$record->append_fields(  MARC::Field->new($ageres_tagid, '', '', $ageres_subfieldid => 'PEGI 16')  );
C4::Biblio::ModBiblio( $record, $bibnum, $frameworkcode );

is( C4::Reserves::CanBookBeReserved($borrowernumber, $biblionumber)->{status} , 'OK', "Reserving an ageRestricted Biblio without a borrower dateofbirth succeeds" );

#Set the dateofbirth for the Borrower making them "too young".
$borrower->{dateofbirth} = DateTime->now->add( years => -15 );
Koha::Patrons->find( $borrowernumber )->set({ dateofbirth => $borrower->{dateofbirth} })->store;

is( C4::Reserves::CanBookBeReserved($borrowernumber, $biblionumber)->{status} , 'ageRestricted', "Reserving a 'PEGI 16' Biblio by a 15 year old borrower fails");

#Set the dateofbirth for the Borrower making them "too old".
$borrower->{dateofbirth} = DateTime->now->add( years => -30 );
Koha::Patrons->find( $borrowernumber )->set({ dateofbirth => $borrower->{dateofbirth} })->store;

is( C4::Reserves::CanBookBeReserved($borrowernumber, $biblionumber)->{status} , 'OK', "Reserving a 'PEGI 16' Biblio by a 30 year old borrower succeeds");

is( C4::Reserves::CanBookBeReserved($borrowernumber, $biblio_with_no_item->{biblionumber})->{status} , '', "Biblio with no item. Status is empty");
       ####
####### EO Bug 13113 <<<
       ####

$item = Koha::Items->find($itemnumber);

ok( C4::Reserves::IsAvailableForItemLevelRequest($item, $patron), "Reserving a book on item level" );

my $pickup_branch = $builder->build({ source => 'Branch' })->{ branchcode };
t::lib::Mocks::mock_preference( 'UseBranchTransferLimits',  '1' );
t::lib::Mocks::mock_preference( 'BranchTransferLimitsType', 'itemtype' );
my $limit = Koha::Item::Transfer::Limit->new(
    {
        toBranch   => $pickup_branch,
        fromBranch => $item->holdingbranch,
        itemtype   => $item->effective_itemtype,
    }
)->store();
is( C4::Reserves::IsAvailableForItemLevelRequest($item, $patron, $pickup_branch), 0, "Item level request not available due to transfer limit" );
t::lib::Mocks::mock_preference( 'UseBranchTransferLimits',  '0' );

# tests for MoveReserve in relation to ConfirmFutureHolds (BZ 14526)
#   hold from A pos 1, today, no fut holds: MoveReserve should fill it
$dbh->do('DELETE FROM reserves', undef, ($bibnum));
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 0);
t::lib::Mocks::mock_preference('AllowHoldDateInFuture', 1);
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
    $bibitems,  1, undef, $expdate, $notes, 'a title', $checkitem, '');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber );
is( $status, '', 'MoveReserve filled hold');
#   hold from A waiting, today, no fut holds: MoveReserve should fill it
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
   $bibitems,  1, undef, $expdate, $notes, 'a title', $checkitem, 'W');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber );
is( $status, '', 'MoveReserve filled waiting hold');
#   hold from A pos 1, tomorrow, no fut holds: not filled
$resdate= dt_from_string();
$resdate->add_duration(DateTime::Duration->new(days => 1));
$resdate=output_pref($resdate);
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
    $bibitems,  1, $resdate, $expdate, $notes, 'a title', $checkitem, '');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber, undef, 1 );
is( $status, 'Reserved', 'MoveReserve did not fill future hold');
$dbh->do('DELETE FROM reserves', undef, ($bibnum));
#   hold from A pos 1, tomorrow, fut holds=2: MoveReserve should fill it
t::lib::Mocks::mock_preference('ConfirmFutureHolds', 2);
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
    $bibitems,  1, $resdate, $expdate, $notes, 'a title', $checkitem, '');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber, undef, 2 );
is( $status, '', 'MoveReserve filled future hold now');
#   hold from A waiting, tomorrow, fut holds=2: MoveReserve should fill it
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
    $bibitems,  1, $resdate, $expdate, $notes, 'a title', $checkitem, 'W');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber, undef, 2 );
is( $status, '', 'MoveReserve filled future waiting hold now');
#   hold from A pos 1, today+3, fut holds=2: MoveReserve should not fill it
$resdate= dt_from_string();
$resdate->add_duration(DateTime::Duration->new(days => 3));
$resdate=output_pref($resdate);
AddReserve($branch_1,  $borrowernumber, $item_bibnum,
    $bibitems,  1, $resdate, $expdate, $notes, 'a title', $checkitem, '');
MoveReserve( $itemnumber, $borrowernumber );
($status)=CheckReserves( $itemnumber, undef, 3 );
is( $status, 'Reserved', 'MoveReserve did not fill future hold of 3 days');
$dbh->do('DELETE FROM reserves', undef, ($bibnum));

$cache->clear_from_cache("MarcStructure-0-$frameworkcode");
$cache->clear_from_cache("MarcStructure-1-$frameworkcode");
$cache->clear_from_cache("default_value_for_mod_marc-");
$cache->clear_from_cache("MarcSubfieldStructure-$frameworkcode");

subtest '_koha_notify_reserve() tests' => sub {

    plan tests => 2;

    my $wants_hold_and_email = {
        wants_digest => '0',
        transports => {
            sms => 'HOLD',
            email => 'HOLD',
            },
        letter_code => 'HOLD'
    };

    my $mp = Test::MockModule->new( 'C4::Members::Messaging' );

    $mp->mock("GetMessagingPreferences",$wants_hold_and_email);

    $dbh->do('DELETE FROM letter');

    my $email_hold_notice = $builder->build({
            source => 'Letter',
            value => {
                message_transport_type => 'email',
                branchcode => '',
                code => 'HOLD',
                module => 'reserves',
                lang => 'default',
            }
        });

    my $sms_hold_notice = $builder->build({
            source => 'Letter',
            value => {
                message_transport_type => 'sms',
                branchcode => '',
                code => 'HOLD',
                module => 'reserves',
                lang=>'default',
            }
        });

    my $hold_borrower = $builder->build({
            source => 'Borrower',
            value => {
                smsalertnumber=>'5555555555',
                email=>'a@b.com',
            }
        })->{borrowernumber};

    C4::Reserves::AddReserve(
        $item->homebranch, $hold_borrower,
        $item->biblionumber );

    ModReserveAffect($item->itemnumber, $hold_borrower, 0);
    my $sms_message_address = $schema->resultset('MessageQueue')->search({
            letter_code     => 'HOLD',
            message_transport_type => 'sms',
            borrowernumber => $hold_borrower,
        })->next()->to_address();
    is($sms_message_address, undef ,"We should not populate the sms message with the sms number, sending will do so");

    my $email_message_address = $schema->resultset('MessageQueue')->search({
            letter_code     => 'HOLD',
            message_transport_type => 'email',
            borrowernumber => $hold_borrower,
        })->next()->to_address();
    is($email_message_address, undef ,"We should not populate the hold message with the email address, sending will do so");

};

subtest 'ReservesNeedReturns' => sub {
    plan tests => 4;

    my $biblioitem = $builder->build_object( { class => 'Koha::Biblioitems' } );
    my $library    = $builder->build_object( { class => 'Koha::Libraries' } );
    my $itemtype   = $builder->build_object( { class => 'Koha::ItemTypes', value => { rentalcharge => 0 } } );
    my $item_info  = {
        biblionumber     => $biblioitem->biblionumber,
        biblioitemnumber => $biblioitem->biblioitemnumber,
        homebranch       => $library->branchcode,
        holdingbranch    => $library->branchcode,
        itype            => $itemtype->itemtype,
    };
    my $item = $builder->build_object( { class => 'Koha::Items', value => $item_info } );
    my $patron   = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { branchcode => $library->branchcode, }
        }
    );

    my $priority = 1;
    my ( $hold_id, $hold );

    t::lib::Mocks::mock_preference('ReservesNeedReturns', 0); # '0' means 'Automatically mark a hold as found and waiting'
    $hold_id = C4::Reserves::AddReserve(
        $library->branchcode, $patron->borrowernumber,
        $item->biblionumber,  '',
        $priority,            undef,
        undef,                '',
        "title for fee",      $item->itemnumber,
    );
    $hold = Koha::Holds->find($hold_id);
    is( $hold->priority, 0, 'If ReservesNeedReturns is 0, priority must have been set to 0' );
    is( $hold->found, 'W', 'If ReservesNeedReturns is 0, found must have been set waiting' );

    $hold->delete; # cleanup

    t::lib::Mocks::mock_preference('ReservesNeedReturns', 1); # '0' means "Don't automatically mark a hold as found and waiting"
    $hold_id = C4::Reserves::AddReserve(
        $library->branchcode, $patron->borrowernumber,
        $item->biblionumber,  '',
        $priority,            undef,
        undef,                '',
        "title for fee",      $item->itemnumber,
    );
    $hold = Koha::Holds->find($hold_id);
    is( $hold->priority, $priority, 'If ReservesNeedReturns is 1, priority must not have been set to changed' );
    is( $hold->found, undef, 'If ReservesNeedReturns is 1, found must not have been set waiting' );
};

subtest 'ChargeReserveFee tests' => sub {

    plan tests => 8;

    my $library = $builder->build_object({ class => 'Koha::Libraries' });
    my $patron  = $builder->build_object({ class => 'Koha::Patrons' });

    my $fee   = 20;
    my $title = 'A title';

    my $context = Test::MockModule->new('C4::Context');
    $context->mock( userenv => { branch => $library->id } );

    my $line = C4::Reserves::ChargeReserveFee( $patron->id, $fee, $title );

    is( ref($line), 'Koha::Account::Line' , 'Returns a Koha::Account::Line object');
    ok( $line->is_debit, 'Generates a debit line' );
    is( $line->debit_type_code, 'RESERVE' , 'generates RESERVE debit_type');
    is( $line->borrowernumber, $patron->id , 'generated line belongs to the passed patron');
    is( $line->amount, $fee , 'amount set correctly');
    is( $line->amountoutstanding, $fee , 'amountoutstanding set correctly');
    is( $line->description, "$title" , 'description is title of reserved item');
    is( $line->branchcode, $library->id , "Library id is picked from userenv and stored correctly" );
};

subtest 'reserves.item_level_hold' => sub {
    plan tests => 2;

    my $item   = $builder->build_sample_item;
    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { branchcode => $item->homebranch }
        }
    );

    subtest 'item level hold' => sub {
        plan tests => 2;
        my $reserve_id =
          AddReserve( $item->homebranch, $patron->borrowernumber,
            $item->biblionumber, undef, 1, undef, undef, '', '',
            $item->itemnumber );

        my $hold = Koha::Holds->find($reserve_id);
        is( $hold->item_level_hold, 1, 'item_level_hold should be set when AddReserve is called with a specific item' );

        # Mark it waiting
        ModReserveAffect( $item->itemnumber, $patron->borrowernumber, 1 );

        # Revert the waiting status
        C4::Reserves::RevertWaitingStatus(
            { itemnumber => $item->itemnumber } );

        $hold = Koha::Holds->find($reserve_id);

        is( $hold->itemnumber, $item->itemnumber, 'Itemnumber should not be removed when the waiting status is revert' );

        $hold->delete;    # cleanup
    };

    subtest 'biblio level hold' => sub {
        plan tests => 3;
        my $reserve_id = AddReserve( $item->homebranch, $patron->borrowernumber,
            $item->biblionumber, undef, 1 );

        my $hold = Koha::Holds->find($reserve_id);
        is( $hold->item_level_hold, 0, 'item_level_hold should not be set when AddReserve is called without a specific item' );

        # Mark it waiting
        ModReserveAffect( $item->itemnumber, $patron->borrowernumber, 1 );

        $hold = Koha::Holds->find($reserve_id);
        is( $hold->itemnumber, $item->itemnumber, 'Itemnumber should be set on hold confirmation' );

        # Revert the waiting status
        C4::Reserves::RevertWaitingStatus( { itemnumber => $item->itemnumber } );

        $hold = Koha::Holds->find($reserve_id);
        is( $hold->itemnumber, undef, 'Itemnumber should be removed when the waiting status is revert' );

        $hold->delete;
    };

};

subtest 'MoveReserve additional test' => sub {

    plan tests => 4;

    # Create the items and patrons we need
    my $biblio = $builder->build_sample_biblio();
    my $itype = $builder->build_object({ class => "Koha::ItemTypes", value => { notforloan => 0 } });
    my $item_1 = $builder->build_sample_item({ biblionumber => $biblio->biblionumber,notforloan => 0, itype => $itype->itemtype });
    my $item_2 = $builder->build_sample_item({ biblionumber => $biblio->biblionumber, notforloan => 0, itype => $itype->itemtype });
    my $patron_1 = $builder->build_object({ class => "Koha::Patrons" });
    my $patron_2 = $builder->build_object({ class => "Koha::Patrons" });

    # Place a hold on the title for both patrons
    my $reserve_1 = AddReserve( $item_1->homebranch, $patron_1->borrowernumber, $biblio->biblionumber, undef, 1 );
    my $reserve_2 = AddReserve( $item_2->homebranch, $patron_2->borrowernumber, $biblio->biblionumber, undef, 1 );
    is($patron_1->holds->next()->reserve_id, $reserve_1, "The 1st patron has a hold");
    is($patron_2->holds->next()->reserve_id, $reserve_2, "The 2nd patron has a hold");

    # Fake the holds queue
    $dbh->do(q{INSERT INTO hold_fill_targets VALUES (?, ?, ?, ?, ?)},undef,($patron_1->borrowernumber,$biblio->biblionumber,$item_1->itemnumber,$item_1->homebranch,0));

    # The 2nd hold should be filed even if the item is preselected for the first hold
    MoveReserve($item_1->itemnumber,$patron_2->borrowernumber);
    is($patron_2->holds->count, 0, "The 2nd patrons no longer has a hold");
    is($patron_2->old_holds->next()->reserve_id, $reserve_2, "The 2nd patrons hold was filled and moved to old holds");

};

sub count_hold_print_messages {
    my $message_count = $dbh->selectall_arrayref(q{
        SELECT COUNT(*)
        FROM message_queue
        WHERE letter_code = 'HOLD' 
        AND   message_transport_type = 'print'
    });
    return $message_count->[0]->[0];
}

# we reached the finish
$schema->storage->txn_rollback();
