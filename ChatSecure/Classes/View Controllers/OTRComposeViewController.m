//
//  OTRComposeViewController.m
//  Off the Record
//
//  Created by David Chiles on 3/4/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "OTRComposeViewController.h"

#import "OTRBuddy.h"
#import "OTRAccount.h"
#import "OTRDatabaseView.h"
#import "OTRLog.h"
#import "OTRDatabaseManager.h"
#import "OTRDatabaseView.h"
#import "OTRAccountsManager.h"
@import YapDatabase;
@import PureLayout;
@import BButton;
#import "OTRBuddyInfoCell.h"
#import "OTRXMPPManager_Private.h"
#import "OTRNewBuddyViewController.h"
#import "OTRChooseAccountViewController.h"
#import "UITableView+ChatSecure.h"

#import <ChatSecureCore/ChatSecureCore-Swift.h>

@import OTRAssets;

static CGFloat OTRBuddyInfoCellHeight = 80.0;

@interface OTRComposeViewController () <UITableViewDataSource, UITableViewDelegate, OTRYapViewHandlerDelegateProtocol, UISearchResultsUpdating, UISearchControllerDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSLayoutConstraint *  tableViewBottomConstraint;
@property (nonatomic, strong) OTRYapViewHandler *viewHandler;
@property (nonatomic, strong) OTRYapViewHandler *searchViewHandler;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong, readonly) YapDatabaseConnection *searchConnection;
@property (nonatomic, strong, readonly) YapDatabaseSearchQueue *searchQueue;
@property (nonatomic, weak, readonly) YapDatabase *database;
@property (nonatomic, weak) YapDatabaseConnection *readWriteConnection;
@property (nonatomic, strong) NSMutableSet <NSString *>*selectedBuddiesIdSet;

@property (nonatomic, strong) UIBarButtonItem *doneBarButtonItem;
@property (nonatomic, strong) UIBarButtonItem *groupBarButtonItem;
@property (nonatomic, strong) UISegmentedControl *inboxArchiveControl;

@end

@implementation OTRComposeViewController

- (instancetype)init {
    if (self = [super init]) {
        self.selectedBuddiesIdSet = [[NSMutableSet alloc] init];
        _database = [OTRDatabaseManager sharedInstance].database;
        _readWriteConnection = [OTRDatabaseManager sharedInstance].readWriteDatabaseConnection;
        _searchConnection = [self.database newConnection];
        _searchConnection.name = @"ComposeViewSearchConnection";
        _searchQueue = [[YapDatabaseSearchQueue alloc] init];
        _selectionModeIsSingle = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor whiteColor];
    
    /////////// Navigation Bar ///////////
    self.title = COMPOSE_STRING();
    
    UIBarButtonItem * cancelBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelButtonPressed:)];
    
    UIImage *checkImage = [UIImage imageNamed:@"ic-check" inBundle:[OTRAssets resourcesBundle] compatibleWithTraitCollection:nil];
    self.doneBarButtonItem = [[UIBarButtonItem alloc] initWithImage:checkImage style:UIBarButtonItemStylePlain target:self action:@selector(doneButtonPressed:)];
    
    self.groupBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GROUP_CHAT_STRING() style:UIBarButtonItemStylePlain target:self action:@selector(groupButtonPressed:)];
    
    
    self.navigationItem.leftBarButtonItem = cancelBarButtonItem;
    self.navigationItem.rightBarButtonItem = self.groupBarButtonItem;
    
    _inboxArchiveControl = [[UISegmentedControl alloc] initWithItems:@[ACTIVE_BUDDIES_STRING(), ARCHIVE_STRING()]];
    _inboxArchiveControl.selectedSegmentIndex = 0;
    [self updateInboxArchiveFilteringAndShowArchived:NO];
    [_inboxArchiveControl addTarget:self action:@selector(inboxArchiveControlValueChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = _inboxArchiveControl;
    
    /////////// TableView ///////////
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = OTRBuddyInfoCellHeight;
    [self.view addSubview:self.tableView];
    
    [self.tableView registerClass:[OTRBuddyInfoCell class] forCellReuseIdentifier:[OTRBuddyInfoCell reuseIdentifier]];
    
    //[self.tableView autoPinToTopLayoutGuideOfViewController:self withInset:0.0];
    [self.tableView autoPinEdgeToSuperviewEdge:ALEdgeTop];
    [self.tableView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
    [self.tableView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
    self.tableViewBottomConstraint = [self.tableView autoPinToBottomLayoutGuideOfViewController:self withInset:0.0];
    
    [self setupSearchController];
    
    //////// View Handlers /////////
    self.viewHandler = [[OTRYapViewHandler alloc] initWithDatabaseConnection:[OTRDatabaseManager sharedInstance].longLivedReadOnlyConnection databaseChangeNotificationName:[DatabaseNotificationName LongLivedTransactionChanges]];
    self.viewHandler.delegate = self;
    [self.viewHandler setup:OTRFilteredBuddiesName groups:@[OTRBuddyGroup]];
    
    self.searchViewHandler = [[OTRYapViewHandler alloc] initWithDatabaseConnection:[OTRDatabaseManager sharedInstance].longLivedReadOnlyConnection databaseChangeNotificationName:[DatabaseNotificationName LongLivedTransactionChanges]];
    self.searchViewHandler.delegate = self;
    NSString *searchViewName = [YapDatabaseConstants extensionName:DatabaseExtensionNameBuddySearchResultsViewName];
    [self.searchViewHandler setup:searchViewName groupBlock:^BOOL(NSString * _Nonnull group, YapDatabaseReadTransaction * _Nonnull transaction) {
        return YES;
    } sortBlock:^NSComparisonResult(NSString * _Nonnull group1, NSString * _Nonnull group2, YapDatabaseReadTransaction * _Nonnull transaction) {
        return [group1 compare:group2];
    }];
    
    
}

- (void)viewWillAppear:(BOOL)animated
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)inboxArchiveControlValueChanged:(id)sender {
    if (![sender isKindOfClass:[UISegmentedControl class]]) {
        return;
    }
    UISegmentedControl *segment = sender;
    BOOL showArchived = NO;
    if (segment.selectedSegmentIndex == 0) {
        showArchived = NO;
    } else if (segment.selectedSegmentIndex == 1) {
        showArchived = YES;
    }
    [self updateInboxArchiveFilteringAndShowArchived:showArchived];
}

- (YapDatabaseViewFiltering *)getFilteringBlock:(BOOL)showArchived {
    YapDatabaseViewFiltering *filtering = [YapDatabaseViewFiltering withObjectBlock:^BOOL(YapDatabaseReadTransaction * _Nonnull transaction, NSString * _Nonnull group, NSString * _Nonnull collection, NSString * _Nonnull key, id  _Nonnull object) {
        if ([object conformsToProtocol:@protocol(OTRThreadOwner)]) {
            id<OTRThreadOwner> threadOwner = object;
            BOOL isArchived = threadOwner.isArchived;
            return showArchived == isArchived;
        }
        return YES;
    }];
    return filtering;
}

- (void) updateInboxArchiveFilteringAndShowArchived:(BOOL)showArchived {
    [[OTRDatabaseManager sharedInstance].readWriteDatabaseConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        YapDatabaseFilteredViewTransaction *fvt = [transaction ext:OTRFilteredBuddiesName];
        YapDatabaseViewFiltering *filtering = [self getFilteringBlock:showArchived];
        [fvt setFiltering:filtering versionTag:[NSUUID UUID].UUIDString];
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupSearchController {
    UITableViewController *searchResultsController = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
    [searchResultsController.tableView registerClass:[OTRBuddyInfoCell class] forCellReuseIdentifier:[OTRBuddyInfoCell reuseIdentifier]];
    
    searchResultsController.tableView.dataSource = self;
    searchResultsController.tableView.delegate = self;
    searchResultsController.tableView.estimatedRowHeight = 120;
    searchResultsController.tableView.rowHeight = UITableViewAutomaticDimension;
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:searchResultsController];
    self.searchController.searchResultsUpdater = self;
    self.searchController.dimsBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = NO;
    self.searchController.delegate = self;
    
    self.definesPresentationContext = YES;
    
    [self.searchController.searchBar sizeToFit];
    //self.searchController.searchBar.placeholder = SEARCH_STRING;
    self.searchController.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchController.searchBar.delegate = self;
    
    self.tableView.tableHeaderView = self.searchController.searchBar;
}

- (BOOL)isSearchResultsControllerTableView:(UITableView *)tableView
{
    UITableViewController *src = (UITableViewController*)self.searchController.searchResultsController;
    if (tableView == src.tableView) {
        return YES;
    }
    return NO;
}

- (OTRYapViewHandler *)viewHandlerForTableView:(UITableView *)tableView {
    if ([self isSearchResultsControllerTableView:tableView]) {
        return self.searchViewHandler;
    }
    return self.viewHandler;
}

- (void)cancelButtonPressed:(id)sender
{
    // Call dismiss from the split view controller instead
    [self.delegate controllerDidCancel:self];
}

- (void)doneButtonPressed:(id)sender
{
    __weak __typeof__(self) weakSelf = self;
    void (^completion)(NSString *) = ^void(NSString *name) {
        __typeof__(self) strongSelf = weakSelf;
        [strongSelf completeSelectingBuddies:strongSelf.selectedBuddiesIdSet groupName:name];
    };
    
    if (self.selectedBuddiesIdSet.count > 1) {
        //Group so need user to select name
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:GROUP_NAME_STRING() message:ENTER_GROUP_NAME_STRING() preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:OK_STRING() style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *name = alertController.textFields.firstObject.text;
            completion(name);
        }];
        
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
            
        }];
        
        [alertController addAction:okAction];
        [alertController addAction:cancelAction];
        
        [alertController addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = GROUP_NAME_STRING();
            
            [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification object:textField queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
                okAction.enabled = textField.text.length > 0;
            }];
        }];
        
        
        [self presentViewController:alertController animated:YES completion:nil];
    } else {
        completion(nil);
    }
}

/** Intended to be called if selecting one buddy or after a group chat is created*/
- (void)completeSelectingBuddies:(NSSet <NSString *>*)buddies groupName:(nullable NSString*)groupName {
    if ([self.delegate respondsToSelector:@selector(controller:didSelectBuddies:accountId:name:)]) {
        //TODO: Naive choosing account just any buddy but should really check that account is connected or show picker
        __block NSString *accountId = nil;
        [self.viewHandler.databaseConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
            NSString *buddyKey  = [buddies anyObject];
            accountId = [OTRBuddy fetchObjectWithUniqueID:buddyKey transaction:transaction].accountUniqueId;
        }];
        [self.delegate controller:self didSelectBuddies:[buddies allObjects] accountId:accountId name:groupName];
    }
}

- (void) groupButtonPressed:(id)sender {
    [self switchSelectionMode];
}

- (void)switchSelectionMode {
    _selectionModeIsSingle = !_selectionModeIsSingle;
    
    // Change from Join Group / Add Buddy
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:0];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
    
    //Update right bar button item
    if (self.selectionModeIsSingle) {
        self.navigationItem.rightBarButtonItem = self.groupBarButtonItem;
    } else {
        self.navigationItem.rightBarButtonItem = self.doneBarButtonItem;
        self.navigationItem.rightBarButtonItem.enabled = NO;
    }
    
    
}

- (BOOL)canAddBuddies
{
    // TODO: we should migrate to a persistent queue so when
    // you add a buddy offline it will eventually work
    // See: https://github.com/ChatSecure/ChatSecure-iOS/issues/679
    return YES;
}

- (id<OTRThreadOwner>)threadOwnerAtIndexPath:(NSIndexPath *)indexPath withTableView:(UITableView *)tableView
{
    NSIndexPath *viewIndexPath = [NSIndexPath indexPathForItem:indexPath.row inSection:0];
    OTRYapViewHandler *viewHandler = [self viewHandlerForTableView:tableView];
    return [viewHandler object:viewIndexPath];
}

- (void)selectedThreadOwner:(NSString *)buddyId{
    if (![buddyId length]) {
        return;
    }
    
    if ([self.selectedBuddiesIdSet containsObject:buddyId]) {
        [self.selectedBuddiesIdSet removeObject:buddyId];
    } else {
        [self.selectedBuddiesIdSet addObject:buddyId];
    }
    
    //Check legth of selected buddies and if none then disable button
    if ([self.selectedBuddiesIdSet count]) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
    } else {
        [self switchSelectionMode];
    }
}
#pragma - mark keyBoardAnimation Methods
- (void)keyboardWillShow:(NSNotification *)notification
{
    [self animateTableViewWithKeyboardNotification:notification];
}
- (void)keyboardWillHide:(NSNotification *)notification
{
    [self animateTableViewWithKeyboardNotification:notification];
}

- (void)animateTableViewWithKeyboardNotification:(NSNotification *)notification
{
    NSDictionary *userInfo = notification.userInfo;
    
    //
    // Get keyboard size.
    NSValue *endFrameValue = userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect keyboardEndFrame = [self.view convertRect:endFrameValue.CGRectValue fromView:nil];
    
    //
    // Get keyboard animation.
    NSNumber *durationValue = userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval animationDuration = durationValue.doubleValue;
    
    NSNumber *curveValue = userInfo[UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationCurve animationCurve = curveValue.intValue;
    
    CGFloat viewHeight = CGRectGetMaxY(self.view.frame);
    CGFloat keyboardY = CGRectGetMinY(keyboardEndFrame);
    
    CGFloat height = viewHeight - keyboardY;
    //If height is less than 0 or it's hiding set to 0
    if ([notification.name isEqualToString:UIKeyboardWillHideNotification] || height < 0) {
        height = 0;
    }
    
    [self animateTableViewToKeyboardHeight:height animationCurve:animationCurve animationDuration:animationDuration];
}

- (void)animateTableViewToKeyboardHeight:(CGFloat)keyBoardHeight animationCurve:(UIViewAnimationCurve)animationCurve animationDuration:(NSTimeInterval)animationDuration
{
    self.tableViewBottomConstraint.constant = -keyBoardHeight;
    void (^animations)() = ^() {
        [self.view layoutIfNeeded];
    };
    [UIView animateWithDuration:animationDuration
                          delay:0.0
                        options:(animationCurve << 16)
                     animations:animations
                     completion:nil];
    
}

#pragma - mark UITableViewDataSource Methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    OTRYapViewHandler *viewHandler = [self viewHandlerForTableView:tableView];
    BOOL canAddBuddies = [self canAddBuddies];
    NSInteger sections = [viewHandler.mappings numberOfSections];
    
    //If we can add buddies and it's not the search table view then add a section
    if (canAddBuddies && ![self isSearchResultsControllerTableView:tableView]) {
        sections += 1;
    }
    return sections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger numberOfRows = 0;
    if (section == 0 && [self canAddBuddies] && ![self isSearchResultsControllerTableView:tableView]) {
        numberOfRows = 1;
    }
    else {
        OTRYapViewHandler *viewHandler = [self viewHandlerForTableView:tableView];
        numberOfRows = [viewHandler.mappings numberOfItemsInSection:0];
    }
   
    return numberOfRows;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if(indexPath.section == 0 && [self canAddBuddies] && ![self isSearchResultsControllerTableView:tableView]) {
        // add new buddy cell
        static NSString *addCellIdentifier = @"addCellIdentifier";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:addCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:addCellIdentifier];
        }
        if (_selectionModeIsSingle) {
            cell.textLabel.text = ADD_BUDDY_STRING();
        } else {
            cell.textLabel.text = JOIN_GROUP_STRING();
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        
        return cell;
    }
    else {
        OTRBuddyInfoCell *cell = [tableView dequeueReusableCellWithIdentifier:[OTRBuddyInfoCell reuseIdentifier] forIndexPath:indexPath];
        NSIndexPath *databaseIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:0];
        id<OTRThreadOwner> threadOwner = [self threadOwnerAtIndexPath:databaseIndexPath withTableView:tableView];
        
        __block OTRAccount *account = nil;
        [OTRDatabaseManager.shared.readOnlyDatabaseConnection readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
            BOOL showAccount = [self shouldShowAccountLabelWithTransaction:transaction];
            if (showAccount) {
                account = [OTRAccount accountForThread:threadOwner transaction:transaction];
            }
        }];
        
        [cell setThread:threadOwner account:account];
        
        [cell.avatarImageView.layer setCornerRadius:(OTRBuddyInfoCellHeight-2.0*OTRBuddyImageCellPadding)/2.0];
        if ([self.selectedBuddiesIdSet containsObject:[threadOwner threadIdentifier]]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        return cell;
    }
    
    
}

/** By default will show account if numAccounts > 0*/
- (BOOL) shouldShowAccountLabelWithTransaction:(YapDatabaseReadTransaction*)transaction {
    NSUInteger numberOfAccounts = 0;
    numberOfAccounts = [OTRAccount numberOfAccountsWithTransaction:transaction];
    if (numberOfAccounts > 1) {
        return YES;
    }
    return NO;
}

#pragma - mark UITableViewDelegate Methods

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return OTRBuddyInfoCellHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return OTRBuddyInfoCellHeight;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if(indexPath.section == 0 && [self canAddBuddies] && ![self isSearchResultsControllerTableView:tableView]) {
        return UITableViewCellEditingStyleNone;
    } else {
        return UITableViewCellEditingStyleDelete;
    }
    
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *accounts = [OTRAccountsManager allAccounts];
    if(indexPath.section == 0 && [self canAddBuddies] && ![self isSearchResultsControllerTableView:tableView])
    {
        if (_selectionModeIsSingle) {
            [self addBuddy:accounts];
        } else {
            // join group
            [self joinGroup:tableView];
        }
    }
    else {
        NSIndexPath *databaseIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:0];
        id<OTRThreadOwner> threadOwner = [self threadOwnerAtIndexPath:databaseIndexPath withTableView:tableView];
        if (self.selectionModeIsSingle == YES) {
            NSSet <NSString *>*buddySet = [NSSet setWithObject:[threadOwner threadIdentifier]];
            [self completeSelectingBuddies:buddySet groupName:nil];
        } else {
            [self selectedThreadOwner:[threadOwner threadIdentifier]];
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    }
}

- (nullable NSArray<UITableViewRowAction *> *)tableView:(UITableView *)tableView editActionsForRowAtIndexPath:(NSIndexPath *)indexPath  {
    NSIndexPath *databaseIndexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:0];
    id <OTRThreadOwner> thread = [self threadOwnerAtIndexPath:databaseIndexPath withTableView:tableView];
    if (!thread) { return nil; }
    return [UITableView editActionsForThread:thread deleteActionAlsoRemovesFromRoster:YES connection:OTRDatabaseManager.shared.readWriteDatabaseConnection];
}

- (void)addBuddy:(NSArray *)accountsAbleToAddBuddies
{
    if ([accountsAbleToAddBuddies count] == 0) {
        return; // No accounts
    }
    
    //add buddy cell
    UIViewController *viewController = nil;
    if([accountsAbleToAddBuddies count] > 1) {
        // pick which account
        OTRChooseAccountViewController *chooser = [[OTRChooseAccountViewController alloc] init];
        chooser.selectionBlock = ^(OTRChooseAccountViewController * _Nonnull chooseVC, OTRAccount * _Nonnull account) {
            OTRNewBuddyViewController *newBuddyVC = [[OTRNewBuddyViewController alloc] initWithAccountId:account.uniqueId];
            [chooseVC.navigationController pushViewController:newBuddyVC animated:YES];
        };
        viewController = chooser;
    }
    else {
        OTRAccount *account = [accountsAbleToAddBuddies firstObject];
        viewController = [[OTRNewBuddyViewController alloc] initWithAccountId:account.uniqueId];
    }
    [self.navigationController pushViewController:viewController animated:YES];
}

- (void) joinGroup:(id)sender {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:JOIN_GROUP_STRING() message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = XMPP_USERNAME_EXAMPLE_STRING();
    }];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = [NSString stringWithFormat:@"%@ (%@)", PASSWORD_STRING(), OPTIONAL_STRING()];
    }];
    UIAlertAction *joinAction = [UIAlertAction actionWithTitle:OK_STRING() style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *jidStr = alertController.textFields.firstObject.text;
        NSString *pass = alertController.textFields.lastObject.text;
        if (!jidStr.length) {
            return;
        }
        XMPPJID *roomJid = [XMPPJID jidWithString:jidStr];
        if (!roomJid) {
            return;
        }
        NSArray *accounts = [OTRAccountsManager allAccounts];
        void (^joinRoom)(OTRAccount *account) = ^void(OTRAccount *account) {
            OTRXMPPManager *xmpp = (OTRXMPPManager*)[OTRProtocolManager.shared protocolForAccount:account];
            if (!xmpp) { return; }
            [xmpp.roomManager joinRoom:roomJid withNickname:account.displayName subject:nil password:pass];
        };
        if (accounts.count > 1) {
            OTRChooseAccountViewController *chooser = [[OTRChooseAccountViewController alloc] init];
            chooser.selectionBlock = ^(OTRChooseAccountViewController * _Nonnull chooseVC, OTRAccount * _Nonnull account) {
                [chooseVC dismissViewControllerAnimated:YES completion:nil];
                joinRoom(account);
            };
            [self.navigationController pushViewController:chooser animated:YES];
        } else {
            joinRoom(accounts.firstObject);
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:CANCEL_STRING() style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:joinAction];
    [alertController addAction:cancel];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma - mark UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self.view endEditing:YES];
}

#pragma - mark YapDatabaseViewUpdate

- (void)didSetupMappings:(OTRYapViewHandler *)handler
{
    UITableView *tableView = nil;
    if (self.searchViewHandler == handler) {
        tableView = ((UITableViewController*)self.searchController.searchResultsController).tableView;
    } else if (self.viewHandler == handler) {
        tableView = self.tableView;
    }
    [tableView reloadData];
}

- (void)didReceiveChanges:(OTRYapViewHandler *)handler sectionChanges:(NSArray<YapDatabaseViewSectionChange *> *)sectionChanges rowChanges:(NSArray<YapDatabaseViewRowChange *> *)rowChanges
{
    if ([sectionChanges count] == 0 && [rowChanges count] == 0)
    {
        // Nothing has changed that affects our tableView
        return;
    }
    
    UITableView *tableView = self.tableView;
    BOOL isSearchViewHandler = NO;
    if (self.searchViewHandler == handler) {
        isSearchViewHandler = YES;
        tableView = ((UITableViewController*)self.searchController.searchResultsController).tableView;
    }
    
    [tableView beginUpdates];
    
    BOOL canAddBuddies = [self canAddBuddies];
    
    for (YapDatabaseViewSectionChange *sectionChange in sectionChanges)
    {
        NSUInteger sectionIndex = sectionChange.index;
        if (canAddBuddies && !isSearchViewHandler) {
            sectionIndex += 1;
        }
        
        switch (sectionChange.type)
        {
            case YapDatabaseViewChangeDelete :
            {
                [tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
                break;
            }
            case YapDatabaseViewChangeInsert :
            {
                [tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex]
                              withRowAnimation:UITableViewRowAnimationAutomatic];
                break;
            }
            case YapDatabaseViewChangeMove :
            case YapDatabaseViewChangeUpdate :
                break;
        }
    }
    
    
    
    for (YapDatabaseViewRowChange *rowChange in rowChanges)
    {
        NSIndexPath *indexPath = rowChange.indexPath;
        NSIndexPath *newIndexPath = rowChange.newIndexPath;
        if (canAddBuddies && !isSearchViewHandler) {
            indexPath = [NSIndexPath indexPathForItem:rowChange.indexPath.row inSection:1];
            newIndexPath = [NSIndexPath indexPathForItem:rowChange.newIndexPath.row inSection:1];
        }
        
        switch (rowChange.type)
        {
            case YapDatabaseViewChangeDelete :
            {
                [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
                break;
            }
            case YapDatabaseViewChangeInsert :
            {
                [tableView insertRowsAtIndexPaths:@[ newIndexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
                break;
            }
            case YapDatabaseViewChangeMove :
            {
                [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
                [tableView insertRowsAtIndexPaths:@[ newIndexPath ]
                                      withRowAnimation:UITableViewRowAnimationAutomatic];
                break;
            }
            case YapDatabaseViewChangeUpdate :
            {
                [tableView reloadRowsAtIndexPaths:@[ indexPath ]
                                      withRowAnimation:UITableViewRowAnimationNone];
                break;
            }
        }
    }
    
    [tableView endUpdates];
}

#pragma - mark UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchString = [self.searchController.searchBar text];
    if ([searchString length]) {
        searchString = [NSString stringWithFormat:@"%@*",searchString];
        [self.searchQueue enqueueQuery:searchString];
        [self.searchConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            NSString *searchViewName = [YapDatabaseConstants extensionName:DatabaseExtensionNameBuddySearchResultsViewName];
            [[transaction ext:searchViewName] performSearchWithQueue:self.searchQueue];
        }];
    }
}

#pragma - mark UISearchControllerDelegate

- (void)willDismissSearchController:(UISearchController *)searchController
{
    //Make sure all the checkmarks are correctly updated
    [self.tableView reloadData];
}


@end
