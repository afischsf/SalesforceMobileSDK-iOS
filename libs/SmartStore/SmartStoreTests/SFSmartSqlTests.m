/*
  Copyright (c) 2013-present, salesforce.com, inc. All rights reserved.
 
  Redistribution and use of this software in source and binary forms, with or without modification,
  are permitted provided that the following conditions are met:
  * Redistributions of source code must retain the above copyright notice, this list of conditions
  and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of
  conditions and the following disclaimer in the documentation and/or other materials provided
  with the distribution.
  * Neither the name of salesforce.com, inc. nor the names of its contributors may be used to
  endorse or promote products derived from this software without specific prior written
  permission of salesforce.com, inc.
 
  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
  IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
  FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY
  WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "SFSmartSqlTests.h"
#import "SFSmartSqlHelper.h"
#import "SFSmartSqlCache.h"
#import "SFSmartStore+Internal.h"
#import "SFSoupIndex.h"
#import "SFQuerySpec.h"
#import <SalesforceSDKCommon/SFJsonUtils.h>

@interface SFOAuthCredentials ()
@property (nonatomic, readwrite, nullable) NSURL *identityUrl;

@end
@interface SFSmartSqlTests ()

@property (nonatomic, strong) SFSmartStore *store;

@end

@interface SFUserAccountManager()
- (void)setCurrentUserInternal:(SFUserAccount *)userAccount;
@end

@implementation SFSmartSqlTests

#pragma mark - setup and teardown

- (void) setUp
{
    [super setUp];
    [[SFUserAccountManager sharedInstance] setCurrentUserInternal: [self createUserAccount]];
    self.store = [SFSmartStore sharedStoreWithName:kTestStore user:[SFUserAccountManager sharedInstance].currentUser];
    
    // Employees soup
    [self.store registerSoup:kEmployeesSoup                               // should be TABLE_1
              withIndexSpecs:[SFSoupIndex asArraySoupIndexes:
                              @[[self createStringIndexSpec:kFirstName],   // should be TABLE_1_0
                                [self createStringIndexSpec:kLastName],    // should be TABLE_1_1
                                [self createStringIndexSpec:kDeptCode],    // should be TABLE_1_2
                                [self createStringIndexSpec:kEmployeeId],  // should be TABLE_1_3
                                [self createStringIndexSpec:kManagerId],   // should be TABLE_1_4
                                [self createFloatingIndexSpec:kSalary],    // should be TABLE_1_5
                                [self createJSON1IndexSpec:kEducation],    // should be json_extract(soup, '$.education')
                                [self createJSON1IndexSpec:kIsManager]     // should be json_extract(soup, '$.isManager')
                                ]]
                       error:nil];

    // Departments soup
    [self.store registerSoup:kDepartmentsSoup                              // should be TABLE_2
              withIndexSpecs:[SFSoupIndex asArraySoupIndexes:
                              @[[self createStringIndexSpec:kDeptCode],    // should be TABLE_2_0
                                [self createStringIndexSpec:kName],        // should be TABLE_2_1
                                [self createIntegerIndexSpec:kBudget],     // should be TABLE_2_2
                                [self createJSON1IndexSpec:kBuilding]      // should be json_extract(soup, '$.building')
                                ]]
                       error:nil];
}

- (void) tearDown
{
    [SFSmartStore removeSharedStoreWithName:kTestStore forUser:[SFUserAccountManager sharedInstance].currentUser];
    self.store = nil;
    [super tearDown];
}

- (SFUserAccount *)createUserAccount
{
    u_int32_t userIdentifier = arc4random();
    SFOAuthCredentials *credentials = [[SFOAuthCredentials alloc] initWithIdentifier:[NSString stringWithFormat:@"identifier-%u", userIdentifier] clientId:[SFUserAccountManager sharedInstance].oauthClientId encrypted:YES];
    SFUserAccount *user =[[SFUserAccount alloc] initWithCredentials:credentials];
    NSString *userId = [NSString stringWithFormat:@"user_%u", userIdentifier];
    NSString *orgId = [NSString stringWithFormat:@"org_%u", userIdentifier];
    user.credentials.identityUrl = [NSURL URLWithString:[NSString stringWithFormat:@"https://test.salesforce.com/id/%@/%@", orgId, userId]];
    [user transitionToLoginState:SFUserAccountLoginStateLoggedIn];
    NSError *error = nil;
    [user transitionToLoginState:SFUserAccountLoginStateLoggedIn];
    [[SFUserAccountManager sharedInstance] saveAccountForUser:user error:&error];
    XCTAssertNil(error);
   
    return user;
}


#pragma mark - tests
// All code under test must be linked into the Unit Test bundle

- (void) testSharedInstance
{
    SFSmartSqlHelper* instance1 = [SFSmartSqlHelper sharedInstance];
    SFSmartSqlHelper* instance2 = [SFSmartSqlHelper sharedInstance];
    XCTAssertEqualObjects(instance1, instance2, @"There should be only one instance");
}

- (void) testConvertSmartSqlWithInsertUpdateDelete
{
    XCTAssertNil([self.store convertSmartSql:@"insert into {employees}"], @"Should have returned nil for a insert query");
    XCTAssertNil([self.store convertSmartSql:@"update {employees}"], @"Should have returned nil for a update query");
    XCTAssertNil([self.store convertSmartSql:@"delete from {employees}"], @"Should have returned nil for a delete query");
    XCTAssertNotNil([self.store convertSmartSql:@"select * from {employees}"], @"Should not have returned nil for a proper query");
}

- (void) testSimpleConvertSmartSql
{
    XCTAssertEqualObjects(@"select TABLE_1_0, TABLE_1_1 from TABLE_1 order by TABLE_1_1",
                         [self.store convertSmartSql:@"select {employees:firstName}, {employees:lastName} from {employees} order by {employees:lastName}"],
                         @"Bad conversion");

    XCTAssertEqualObjects(@"select TABLE_2_1 from TABLE_2 order by TABLE_2_0",
                         [self.store convertSmartSql:@"select {departments:name} from {departments} order by {departments:deptCode}"],
                         @"Bad conversion");
}


- (void) testConvertSmartSqlWithJoin
{
    XCTAssertEqualObjects(@"select TABLE_2_1, TABLE_1_0 || ' ' || TABLE_1_1 "
                         "from TABLE_1, TABLE_2 "
                         "where TABLE_2_0 = TABLE_1_2 "
                         "order by TABLE_2_1, TABLE_1_1",
                         [self.store convertSmartSql:@"select {departments:name}, {employees:firstName} || ' ' || {employees:lastName} "
                                 "from {employees}, {departments} "
                             "where {departments:deptCode} = {employees:deptCode} "
                                 "order by {departments:name}, {employees:lastName}"],
                         @"Bad conversion");
}

- (void) testConvertSmartSqlWithSelfJoin
{
    XCTAssertEqualObjects(@"select mgr.TABLE_1_1, e.TABLE_1_1 "
                         "from TABLE_1 as mgr, TABLE_1 as e "
                         "where mgr.TABLE_1_3 = e.TABLE_1_4",
                         [self.store convertSmartSql:@"select mgr.{employees:lastName}, e.{employees:lastName} "
                                 "from {employees} as mgr, {employees} as e "
                           "where mgr.{employees:employeeId} = e.{employees:managerId}"],
                         @"Bad conversion");
}

- (void) testConvertSmartSqlWithSpecialColumns
{
    XCTAssertEqualObjects(@"select TABLE_1.id, TABLE_1.created, TABLE_1.lastModified, TABLE_1.soup from TABLE_1",
                         [self.store convertSmartSql:@"select {employees:_soupEntryId}, {employees:_soupCreatedDate}, {employees:_soupLastModifiedDate}, {employees:_soup} from {employees}"], @"Bad conversion");
}
	
- (void) testConvertSmartSqlWithSpecialColumnsAndJoin
{
    XCTAssertEqualObjects(@"select TABLE_1.id, TABLE_2.id from TABLE_1, TABLE_2", 
                         [self.store convertSmartSql:@"select {employees:_soupEntryId}, {departments:_soupEntryId} from {employees}, {departments}"], @"Bad conversion");
}

- (void) testConvertSmartSqlWithSpecialColumnsAndSelfJoin
{
    XCTAssertEqualObjects(@"select mgr.id, e.id from TABLE_1 as mgr, TABLE_1 as e", 
                         [self.store convertSmartSql:@"select mgr.{employees:_soupEntryId}, e.{employees:_soupEntryId} from {employees} as mgr, {employees} as e"], @"Bad conversion");
}

- (void) testConvertSmartSqlWithJSON1
{
    if ([[self.store attributesForSoup:kEmployeesSoup].features containsObject:kSoupFeatureExternalStorage]) {
        [SFSDKSmartStoreLogger i:[self class] format:@"Test Skipped for soup with external storage feature."];
        return;
    }
    XCTAssertEqualObjects(@"select TABLE_1_1, json_extract(soup, '$.education') from TABLE_1 where json_extract(soup, '$.education') = 'MIT'",
                          [self.store convertSmartSql:@"select {employees:lastName}, {employees:education} from {employees} where {employees:education} = 'MIT'"], @"Bad conversion");
}

- (void) testConvertSmartSqlWithJSON1AndTableQualifiedColumn
{
    if ([[self.store attributesForSoup:kEmployeesSoup].features containsObject:kSoupFeatureExternalStorage]) {
        [SFSDKSmartStoreLogger i:[self class] format:@"Test Skipped for soup with external storage feature."];
        return;
    }
    XCTAssertEqualObjects(@"select json_extract(TABLE_1.soup, '$.education') from TABLE_1 order by json_extract(TABLE_1.soup, '$.education')",
                          [self.store convertSmartSql:@"select {employees}.{employees:education} from {employees} order by {employees}.{employees:education}"], @"Bad conversion");
}

- (void) testConvertSmartSqlWithJSON1AndTableAliases
{
    if ([[self.store attributesForSoup:kEmployeesSoup].features containsObject:kSoupFeatureExternalStorage]) {
        [SFSDKSmartStoreLogger i:[self class] format:@"Test Skipped for soup with external storage feature."];
        return;
    }
    XCTAssertEqualObjects(@"select json_extract(e.soup, '$.education'), json_extract(soup, '$.building') from TABLE_1 as e, TABLE_2",
                          [self.store convertSmartSql:@"select e.{employees:education}, {departments:building} from {employees} as e, {departments}"], @"Bad conversion");
    
    // XXX join query with json1 will only run if all the json1 columns are qualified by table or alias
}

- (void) testConvertSmartSqlForNonIndexedColumns {
    XCTAssertEqualObjects(@"select json_extract(soup, '$.education'), json_extract(soup, '$.address.zipcode') from TABLE_1 where json_extract(soup, '$.address.city') = 'San Francisco'", [self.store convertSmartSql:@"select {employees:education}, {employees:address.zipcode} from {employees} where {employees:address.city} = 'San Francisco'"], @"Bad conversion");
}

- (void) testConvertSmartSqlWithQuotedCurlyBraces {
    XCTAssertEqualObjects(@"select json_extract(soup, '$.education') from TABLE_1 where json_extract(soup, '$.education') like 'Account(where: {Name: {eq: \"Jason\"}})'",
                        [self.store convertSmartSql:@"select {employees:education} from {employees} where {employees:education} like 'Account(where: {Name: {eq: \"Jason\"}})'"]);
}

- (void) testConvertSmartSqlWithMultipleQuotedCurlyBraces {
    XCTAssertEqualObjects(@"select json_extract(soup, '$.education'), '{a:b}', TABLE_1_0 from TABLE_1 where json_extract(soup, '$.address') = '{\"city\": \"San Francisco\"}' or TABLE_1_1 like 'B%'",
                          [self.store convertSmartSql:@"select {employees:education}, '{a:b}', {employees:firstName} from {employees} where {employees:address} = '{\"city\": \"San Francisco\"}' or {employees:lastName} like 'B%'"]);
}

- (void) testConvertSmartSqlWithQuotedUnbalancedCurlyBrace {
    XCTAssertEqualObjects(@"select json_extract(soup, '$.education') from TABLE_1 where json_extract(soup, '$.education') like ' { { { } } '",
                          [self.store convertSmartSql:@"select {employees:education} from {employees} where {employees:education} like ' { { { } } '"]);
}


- (void) testSmartQueryDoingCount 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select count(*) from {employees}" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0 error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[7]]"] actual:result message:@"Wrong result"];
}
	
- (void) testSmartQueryDoingSum 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select sum({departments:budget}) from {departments}" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[3000000]]"] actual:result message:@"Wrong result"];
}

- (void) testSmartQueryReturningOneRowWithOneInteger 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:salary} from {employees} where {employees:lastName} = 'Haas'" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[200000.10]]"] actual:result message:@"Wrong result"];
}
	
- (void) testSmartQueryReturningOneRowWithTwoIntegers 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select mgr.{employees:salary}, e.{employees:salary} from {employees} as mgr, {employees} as e where mgr.{employees:employeeId} = e.{employees:managerId} and e.{employees:lastName} = 'Thompson'" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[200000.10,120000.10]]"] actual:result message:@"Wrong result"];
}

- (void) testSmartQueryReturningTwoRowsWithOneIntegerEach 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:salary} from {employees} where {employees:managerId} = '00010' order by {employees:firstName}" withPageSize:2];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0 error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[120000.10],[100000.10]]"] actual:result message:@"Wrong result"];
}

- (void) testSmartQueryReturningSoupStringAndInteger 
{
    [self loadData];
    SFQuerySpec* exactQuerySpec = [SFQuerySpec newExactQuerySpec:kEmployeesSoup withPath:@"employeeId" withMatchKey:@"00010" withOrderPath:@"employeeId" withOrder:kSFSoupQuerySortOrderAscending withPageSize:1];
    NSDictionary* christineJson = [self.store queryWithQuerySpec:exactQuerySpec pageIndex:0  error:nil][0];
    XCTAssertEqualObjects(@"Christine", christineJson[kFirstName], @"Wrong elt");
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:_soup}, {employees:firstName}, {employees:salary} from {employees} where {employees:lastName} = 'Haas'" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    XCTAssertTrue(1 == [result count], @"Expected one row");
    [self assertSameJSONWithExpected:christineJson actual:result[0][0] message:@"Wrong soup"];
    XCTAssertEqualObjects(@"Christine", result[0][1], @"Wrong first name");
    NSNumber* dubNum = result[0][2];
    XCTAssertEqual(200000.10, [dubNum doubleValue], @"Wrong salary");
}
	
- (void) testSmartQueryWithPaging 
{
    [self loadData];
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:firstName} from {employees} order by {employees:firstName}" withPageSize:1];
    XCTAssertTrue(7 ==[[self.store countWithQuerySpec:querySpec  error:nil] unsignedIntegerValue], @"Expected 7 employees");
    NSArray* expectedResults = @[@"Christine", @"Eileen", @"Eva", @"Irving", @"John", @"Michael", @"Sally"];
    for (int i=0; i<7; i++) {
        NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:i  error:nil];
        NSArray* expectedResult = @[@[expectedResults[i]]];
        NSString* message = [NSString stringWithFormat:@"Wrong result at page %d", i];
        [self assertSameJSONArrayWithExpected:expectedResult actual:result message:message];
    }
}
    
- (void) testSmartQueryWithSpecialFields 
{
    [self loadData];
    SFQuerySpec* exactQuerySpec = [SFQuerySpec newExactQuerySpec:kEmployeesSoup withPath:@"employeeId" withMatchKey:@"00010" withOrderPath:@"employeeId" withOrder:kSFSoupQuerySortOrderAscending withPageSize:1];
    NSDictionary* christineJson = [self.store queryWithQuerySpec:exactQuerySpec pageIndex:0  error:nil][0];
    XCTAssertEqualObjects(@"Christine", christineJson[kFirstName], @"Wrong elt");
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:_soup}, {employees:_soupEntryId}, {employees:_soupLastModifiedDate} from {employees} where {employees:lastName} = 'Haas'" withPageSize:1];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    XCTAssertTrue(1 == [result count], @"Expected one row");
    [self assertSameJSONWithExpected:christineJson actual:result[0][0] message:@"Wrong soup"];
    XCTAssertEqualObjects(christineJson[@"_soupEntryId"], result[0][1], @"Wrong soupEntryId");
    XCTAssertEqualObjects(christineJson[@"_soupLastModifiedDate"], result[0][2], @"Wrong soupLastModifiedDate");
}

- (void) testSmartQueryWithNullField
{
    NSDictionary* createdEmployee;
    
    // Employee with dept code
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"001\",\"deptCode\":\"xyz\"}"];
    XCTAssertEqualObjects(createdEmployee[@"deptCode"], @"xyz");
    
    // Employee with [NSNull null] dept code
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"002\",\"deptCode\":null}"];
    XCTAssertEqual(createdEmployee[@"deptCode"], [NSNull null]);
    
    // Employee with @"" dept code
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"003\",\"deptCode\":\"\"}"];
    XCTAssertEqualObjects(createdEmployee[@"deptCode"], @"");
    
    // Employee with no dept code
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"004\"}"];
    XCTAssertEqual(createdEmployee[@"deptCode"], nil);
    
    // Smart sql with is not null
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:deptCode} is not null order by {employees:employeeId}" withPageSize:4];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"001\"],[\"003\"]]"] actual:result message:@"Wrong result"];

    // Smart sql with is null
    querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:deptCode} is null order by {employees:employeeId}" withPageSize:4];
    result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"002\"],[\"004\"]]"] actual:result message:@"Wrong result"];
    
    // Smart sql looking for empty string
    querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:deptCode} = \"\" order by {employees:employeeId}" withPageSize:4];
    result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"003\"]]"] actual:result message:@"Wrong result"];
    
    // Smart sql returning null values
    querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId},{employees:deptCode},{employees:deptCode} from {employees} order by {employees:employeeId}" withPageSize:4];
    result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"001\",\"xyz\",\"xyz\"],[\"002\",null,null],[\"003\",\"\",\"\"],[\"004\",null,null]]"] actual:result message:@"Wrong result"];
}

- (void) testSmartQueryMachingBooleanInJSON1Field
{
    NSDictionary* createdEmployee;
    
    // Storing booleans in a json1 field
    // NB: SQLite does not have a separate Boolean storage class. Instead, Boolean values are stored as integers 0 (false) and 1 (true).

    [self loadData];
    
    // Creating another employee from a json string with isManager true
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"101\",\"isManager\":true}"];
    XCTAssertEqual(createdEmployee[kIsManager], @YES);

    // Creating another employee from a json string with isManager false
    createdEmployee = [self createEmployeeWithJsonString:@"{\"employeeId\":\"102\",\"isManager\":false}"];
    XCTAssertEqual(createdEmployee[kIsManager], @NO);
    
    // Smart sql looking for isManager true
    SFQuerySpec* querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:isManager} = 1 order by {employees:employeeId}" withPageSize:10];
    NSArray* result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"00010\"],[\"00040\"],[\"00050\"],[\"101\"]]"] actual:result message:@"Wrong result"];
    // Smart sql looking for isManager = false
    querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:isManager} = 0 order by {employees:employeeId}" withPageSize:10];
    result = [self.store queryWithQuerySpec:querySpec pageIndex:0  error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"00020\"],[\"00060\"],[\"00070\"],[\"00310\"],[\"102\"]]"] actual:result message:@"Wrong result"];
}

- (void)testSmartQueryFilteringByNonIndexedField {
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"101\",\"address\":{\"city\":\"San Francisco\", \"zipcode\":94105}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"102\",\"address\":{\"city\":\"New York City\", \"zipcode\":10004}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"103\",\"address\":{\"city\":\"San Francisco\", \"zipcode\":94106}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"104\",\"address\":{\"city\":\"New York City\", \"zipcode\":10006}}"];

    SFQuerySpec *querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId} from {employees} where {employees:address.city} = 'San Francisco' order by {employees:employeeId}" withPageSize:10];
    NSArray *result = [self.store queryWithQuerySpec:querySpec pageIndex:0 error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"101\"],[\"103\"]]"] actual:result message:@"Wrong result"];
}

- (void)testSmartQueryReturningNonIndexedField {
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"101\",\"address\":{\"city\":\"San Francisco\", \"zipcode\":94105}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"102\",\"address\":{\"city\":\"New York City\", \"zipcode\":10004}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"103\",\"address\":{\"city\":\"San Francisco\", \"zipcode\":94106}}"];
    [self createEmployeeWithJsonString:@"{\"employeeId\":\"104\",\"address\":{\"city\":\"New York City\", \"zipcode\":10006}}"];
    
    SFQuerySpec *querySpec = [SFQuerySpec newSmartQuerySpec:@"select {employees:employeeId}, {employees:address.zipcode} from {employees} where {employees:address.city} = 'San Francisco' order by {employees:employeeId}" withPageSize:10];
    NSArray *result = [self.store queryWithQuerySpec:querySpec pageIndex:0 error:nil];
    [self assertSameJSONArrayWithExpected:[SFJsonUtils objectFromJSONString:@"[[\"101\", 94105],[\"103\", 94106]]"] actual:result message:@"Wrong result"];
}

#pragma mark - helper methods
- (void)loadData {
    // Employees
    [self createEmployeeWithFirstName:@"Christine" withLastName:@"Haas" withDeptCode:@"A00" withEmployeeId:@"00010" withManagerId:@"" withSalary:200000.10 withIsManager:YES];
    [self createEmployeeWithFirstName:@"Michael" withLastName:@"Thompson" withDeptCode:@"A00" withEmployeeId:@"00020" withManagerId:@"00010" withSalary:120000.10 withIsManager:NO];
    [self createEmployeeWithFirstName:@"Sally" withLastName:@"Kwan" withDeptCode:@"A00" withEmployeeId:@"00310" withManagerId:@"00010" withSalary:100000.10 withIsManager:NO];
    [self createEmployeeWithFirstName:@"John" withLastName:@"Geyer" withDeptCode:@"B00" withEmployeeId:@"00040" withManagerId:@"" withSalary:102000.10 withIsManager:YES];
    [self createEmployeeWithFirstName:@"Irving" withLastName:@"Stern" withDeptCode:@"B00" withEmployeeId:@"00050" withManagerId:@"00040" withSalary:100000.10 withIsManager:YES];
    [self createEmployeeWithFirstName:@"Eva" withLastName:@"Pulaski" withDeptCode:@"B00" withEmployeeId:@"00060" withManagerId:@"00050" withSalary:80000.10 withIsManager:NO];
    [self createEmployeeWithFirstName:@"Eileen" withLastName:@"Henderson" withDeptCode:@"B00" withEmployeeId:@"00070" withManagerId:@"00050" withSalary:70000.10 withIsManager:NO];
		
    // Departments
    [self createDepartmentWithCode:@"A00" withName:@"Sales" withBudget:1000000];
    [self createDepartmentWithCode:@"B00" withName:@"R&D" withBudget:2000000];
}

- (void)createEmployeeWithFirstName:(NSString *)firstName withLastName:(NSString *)lastName withDeptCode:(NSString *)deptCode withEmployeeId:(NSString *)employeeId withManagerId:(NSString *)managerId withSalary:(double)salary withIsManager:(BOOL)isManager {
    NSDictionary *employee = @{kFirstName: firstName, kLastName: lastName, kDeptCode: deptCode, kEmployeeId: employeeId, kManagerId: managerId, kSalary: @(salary), kIsManager: @(isManager)};
    [self.store upsertEntries:@[employee] toSoup:kEmployeesSoup];
}

- (NSDictionary *)createEmployeeWithJsonString:(NSString*)jsonString {
    NSDictionary *employee = [SFJsonUtils objectFromJSONString:jsonString];
    return [self.store upsertEntries:@[employee] toSoup:kEmployeesSoup][0];
}
	
- (void)createDepartmentWithCode:(NSString *)deptCode withName:(NSString *)name withBudget:(NSUInteger)budget {
    NSDictionary *department = @{kDeptCode: deptCode, kName: name, kBudget: @(budget)};
    [self.store upsertEntries:@[department] toSoup:kDepartmentsSoup];
}

@end
