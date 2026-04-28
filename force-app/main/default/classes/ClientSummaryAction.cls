/**
 * @description  Invocable Apex Action — Client 360 Summary (v4)
 *               AccountContactRelation is queried via Database.query()
 *               and fields are accessed via SObject.get() to avoid the
 *               "Invalid type: AccountContactRelation" compile error
 *               in orgs where the type is not directly available in Apex.
 *
 *  Household detection:
 *    - RecordType.DeveloperName / Name contains 'household' or 'group'
 *    - OR non-PersonAccount that has AccountContactRelation records
 *
 *  Financial data resolution (2-strategy fallback):
 *    Strategy 1 : FinancialAccountParty WHERE AccountId = acc.Id
 *    Strategy 2 : SecuritiesHolding     WHERE PrimaryOwnerId = acc.Id
 */
public with sharing class ClientSummaryAction {

    /* ─────────────────────────────────────────────
       INPUT / OUTPUT
    ───────────────────────────────────────────── */
    public class InputParams {
        @InvocableVariable(
            label='Account Name'
            description='Full name of the client or household, e.g. Priya Mehta or Puri Family'
            required=true)
        public String accountName;
    }

    public class OutputParams {
        @InvocableVariable(label='Client Summary')
        public String summary;

        @InvocableVariable(label='Status')
        public String status;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /* ─────────────────────────────────────────────
       ENTRY POINT
    ───────────────────────────────────────────── */
    @InvocableMethod(
        label='Get Client 360 Summary'
        description='Returns a complete 360 summary for a client or household by Account Name.'
        category='Client Intelligence'
    )
    public static List<OutputParams> getSummary(List<InputParams> inputs) {
        List<OutputParams> results = new List<OutputParams>();
        for (InputParams input : inputs) {
            OutputParams out = new OutputParams();
            try {
                out.summary      = buildSummary(input.accountName);
                out.status       = 'SUCCESS';
                out.errorMessage = null;
            } catch (ClientNotFoundException e) {
                out.summary      = null;
                out.status       = 'ERROR';
                out.errorMessage = e.getMessage();
            } catch (Exception e) {
                out.summary      = null;
                out.status       = 'ERROR';
                out.errorMessage = 'Unexpected error: ' + e.getMessage();
            }
            results.add(out);
        }
        return results;
    }

    /* ─────────────────────────────────────────────
       CORE ROUTING
    ───────────────────────────────────────────── */
    private static String buildSummary(String accountName) {

        if (String.isBlank(accountName)) {
            throw new ClientNotFoundException('Account name cannot be blank.');
        }

        List<Account> accounts = [
            SELECT
                Id, Name, FirstName, LastName,
                PersonEmail, PersonMobilePhone, Phone,
                PersonBirthdate,
                PersonTitle, PersonDepartment,
                BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                PersonMailingStreet, PersonMailingCity, PersonMailingState,
                PersonMailingPostalCode, PersonMailingCountry,
                Industry, Type, Rating, AnnualRevenue, NumberOfEmployees,
                AccountSource, Ownership, Description, Website,
                SourceSystemIdentifier, sent_Interaction__c,
                IsActive, HasPrivacyHold, IsPersonAccount,
                RecordType.Name, RecordType.DeveloperName,
                CreatedDate, LastModifiedDate
            FROM Account
            WHERE Name = :accountName.trim()
            LIMIT 1
        ];

        if (accounts.isEmpty()) {
            throw new ClientNotFoundException(
                'No client or household found with the name "' + accountName + '". '
              + 'Please verify the name and try again.'
            );
        }

        Account acc = accounts[0];

        if (isHouseholdAccount(acc)) {
            return buildHouseholdSummary(acc);
        }
        return buildIndividualSummary(acc);
    }

    /* ─────────────────────────────────────────────
       HOUSEHOLD DETECTION
    ───────────────────────────────────────────── */
    private static Boolean isHouseholdAccount(Account acc) {
        if (acc.RecordType != null) {
            String rtDev = acc.RecordType.DeveloperName != null
                           ? acc.RecordType.DeveloperName.toLowerCase()
                           : acc.RecordType.Name.toLowerCase();
            if (rtDev.contains('household') || rtDev.contains('group')) {
                return true;
            }
        }
        // Fallback: non-PersonAccount that has ACR members — use dynamic SOQL
        if (acc.IsPersonAccount == false) {
            Integer acrCount = Database.countQuery(
                'SELECT COUNT() FROM AccountContactRelation WHERE AccountId = \'' + acc.Id + '\''
            );
            return acrCount > 0;
        }
        return false;
    }

    /* ─────────────────────────────────────────────
       HOUSEHOLD SUMMARY
       AccountContactRelation queried via Database.query()
       and all fields accessed via SObject.get()
    ───────────────────────────────────────────── */
    private static String buildHouseholdSummary(Account household) {
        List<String> lines = new List<String>();

        lines.add('==========================================================');
        lines.add('  HOUSEHOLD 360 SUMMARY -- ' + household.Name.toUpperCase());
        lines.add('==========================================================');

        lines.add('\nHOUSEHOLD DETAILS');
        lines.add('--------------------------');
        addLine(lines, 'Household Name',  household.Name);
        addLine(lines, 'Type',            household.Type);
        addLine(lines, 'Status',          household.IsActive ? 'Active' : 'Inactive');
        addLine(lines, 'Billing Address',
            buildAddress(household.BillingStreet, household.BillingCity,
                         household.BillingState, household.BillingPostalCode, household.BillingCountry));
        addLine(lines, 'Record Created',
            household.CreatedDate != null ? household.CreatedDate.format() : null);
        addLine(lines, 'Last Modified',
            household.LastModifiedDate != null ? household.LastModifiedDate.format() : null);
        if (String.isNotBlank(household.Description)) {
            lines.add('Description            : ' + household.Description);
        }

        // Fetch members via dynamic SOQL — avoids "Invalid type" compile error
        String acrQuery =
            'SELECT Id, AccountId, ContactId, ' +
            'Contact.Name, Contact.AccountId, ' +
            'Roles, IsPrimaryMember, IsActive, ' +
            'IsDecisionMakingAuthority, IsDirect, IsPrimaryGroup, ' +
            'IsShareholder, ShareholderType, ShareholderHierarchyLevel, ' +
            'ShareholderHierarchyRole, TotalSharePercent, ' +
            'StartDate, EndDate, DeclarationType ' +
            'FROM AccountContactRelation ' +
            'WHERE AccountId = \'' + household.Id + '\' ' +
            'ORDER BY IsPrimaryMember DESC, StartDate ASC NULLS LAST';

        List<SObject> acrList = Database.query(acrQuery);

        lines.add('\nHOUSEHOLD MEMBERS (' + acrList.size() + ')');
        lines.add('--------------------------');

        if (acrList.isEmpty()) {
            lines.add('  No members found in this household.');
        } else {

            // Gather member Person Account Ids via SObject.get()
            Set<Id> memberAccountIds = new Set<Id>();
            for (SObject acrRec : acrList) {
                SObject contactRel = acrRec.getSObject('Contact');
                if (contactRel != null) {
                    Id personAccId = (Id) contactRel.get('AccountId');
                    if (personAccId != null) {
                        memberAccountIds.add(personAccId);
                    }
                }
            }

            // Fetch full Person Account details for all members in one query
            Map<Id, Account> memberAccounts = new Map<Id, Account>();
            if (!memberAccountIds.isEmpty()) {
                for (Account ma : [
                    SELECT
                        Id, Name, FirstName, LastName,
                        PersonEmail, PersonMobilePhone, Phone,
                        PersonBirthdate,
                        PersonTitle, PersonDepartment,
                        BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                        PersonMailingStreet, PersonMailingCity, PersonMailingState,
                        PersonMailingPostalCode, PersonMailingCountry,
                        Industry, Type, Rating, AnnualRevenue, NumberOfEmployees,
                        AccountSource, Ownership, Description, Website,
                        SourceSystemIdentifier, sent_Interaction__c,
                        IsActive, HasPrivacyHold,
                        CreatedDate, LastModifiedDate
                    FROM Account
                    WHERE Id IN :memberAccountIds
                ]) {
                    memberAccounts.put(ma.Id, ma);
                }
            }

            // Per-Member Block — all ACR fields via SObject.get()
            Integer memberIndex = 1;
            for (SObject acrRec : acrList) {

                SObject contactRel = acrRec.getSObject('Contact');
                Id memberAccId     = (contactRel != null) ? (Id) contactRel.get('AccountId') : null;
                Account member     = (memberAccId != null) ? memberAccounts.get(memberAccId) : null;

                String contactName = (contactRel != null) ? (String) contactRel.get('Name') : 'Unknown Member';
                String mName       = (member != null) ? member.Name : contactName;

                lines.add('\n  +-- MEMBER #' + memberIndex++ + ' -- ' + mName.toUpperCase() + ' ---');
                lines.add('  |  Relationship Details:');

                // Read ACR fields safely via get()
                String  roles       = strVal(acrRec.get('Roles'));
                Boolean isPrimary   = boolVal(acrRec.get('IsPrimaryMember'));
                Boolean isActive    = boolVal(acrRec.get('IsActive'));
                Boolean isDMA       = boolVal(acrRec.get('IsDecisionMakingAuthority'));
                Boolean isDirect    = boolVal(acrRec.get('IsDirect'));
                Boolean isPrimGrp   = boolVal(acrRec.get('IsPrimaryGroup'));
                Boolean isShareholder = boolVal(acrRec.get('IsShareholder'));
                Date    startDate   = (Date)    acrRec.get('StartDate');
                Date    endDate     = (Date)    acrRec.get('EndDate');
                Decimal sharePercent = (Decimal) acrRec.get('TotalSharePercent');

                addLinePfx(lines, '  |    ', 'Role(s)',                   roles);
                addLinePfx(lines, '  |    ', 'Primary Member',            isPrimary   ? 'Yes' : 'No');
                addLinePfx(lines, '  |    ', 'Active',                    isActive    ? 'Yes' : 'No');
                addLinePfx(lines, '  |    ', 'Decision Making Authority', isDMA       ? 'Yes' : 'No');
                addLinePfx(lines, '  |    ', 'Direct',                    isDirect    ? 'Yes' : 'No');
                addLinePfx(lines, '  |    ', 'Primary Group',             isPrimGrp   ? 'Yes' : 'No');
                addLinePfx(lines, '  |    ', 'Shareholder',               isShareholder ? 'Yes' : 'No');

                if (isShareholder) {
                    addLinePfx(lines, '  |    ', 'Shareholder Type',
                        strVal(acrRec.get('ShareholderType')));
                    Object shLevel = acrRec.get('ShareholderHierarchyLevel');
                    addLinePfx(lines, '  |    ', 'Hierarchy Level',
                        shLevel != null ? String.valueOf(shLevel) : null);
                    addLinePfx(lines, '  |    ', 'Hierarchy Role',
                        strVal(acrRec.get('ShareholderHierarchyRole')));
                    addLinePfx(lines, '  |    ', 'Total Share %',
                        sharePercent != null ? sharePercent.setScale(2) + '%' : null);
                }

                addLinePfx(lines, '  |    ', 'Declaration Type',
                    strVal(acrRec.get('DeclarationType')));
                addLinePfx(lines, '  |    ', 'Member Since',
                    startDate != null ? startDate.format() : null);
                addLinePfx(lines, '  |    ', 'Member Until',
                    endDate   != null ? endDate.format()   : null);

                if (member != null) {
                    lines.add('  |');
                    lines.add('  |  Personal Information:');
                    addLinePfx(lines, '  |    ', 'Full Name',    member.Name);
                    addLinePfx(lines, '  |    ', 'Email',        member.PersonEmail);
                    addLinePfx(lines, '  |    ', 'Mobile',       member.PersonMobilePhone);
                    addLinePfx(lines, '  |    ', 'Phone',        member.Phone);
                    addLinePfx(lines, '  |    ', 'Date of Birth',
                        member.PersonBirthdate != null ? member.PersonBirthdate.format() : null);
                    addLinePfx(lines, '  |    ', 'Title',        member.PersonTitle);
                    addLinePfx(lines, '  |    ', 'Privacy Hold', member.HasPrivacyHold ? 'Yes' : 'No');
                    addLinePfx(lines, '  |    ', 'Status',       member.IsActive ? 'Active' : 'Inactive');
                    addLinePfx(lines, '  |    ', 'Mailing Address',
                        buildAddress(member.PersonMailingStreet, member.PersonMailingCity,
                                     member.PersonMailingState, member.PersonMailingPostalCode,
                                     member.PersonMailingCountry));
                    lines.add('  |');
                    lines.add('  |  Financial Accounts & Holdings:');
                    appendFinancialSection(lines, member, '  |    ');
                } else {
                    lines.add('  |  Person Account record not found for this contact.');
                }

                lines.add('  +--------------------------------------------------------------');
            }

            // Household portfolio aggregate
            lines.add('\n==========================================================');
            lines.add('  HOUSEHOLD PORTFOLIO AGGREGATE');
            lines.add('==========================================================');
            appendHouseholdAggregate(lines, memberAccountIds);
        }

        lines.add('\n==========================================================');
        lines.add('  END OF HOUSEHOLD SUMMARY -- ' + household.Name.toUpperCase());
        lines.add('==========================================================');

        return String.join(lines, '\n');
    }

    /* ─────────────────────────────────────────────
       INDIVIDUAL SUMMARY
    ───────────────────────────────────────────── */
    private static String buildIndividualSummary(Account acc) {
        List<String> lines = new List<String>();

        lines.add('==========================================');
        lines.add('  CLIENT 360 SUMMARY -- ' + acc.Name.toUpperCase());
        lines.add('==========================================');

        lines.add('\nPERSONAL INFORMATION');
        lines.add('--------------------------');
        addLine(lines, 'Full Name',        acc.Name);
        addLine(lines, 'Email',            acc.PersonEmail);
        addLine(lines, 'Mobile',           acc.PersonMobilePhone);
        addLine(lines, 'Phone',            acc.Phone);
        addLine(lines, 'Date of Birth',
            acc.PersonBirthdate != null ? acc.PersonBirthdate.format() : null);
        addLine(lines, 'Title',            acc.PersonTitle);
        addLine(lines, 'Department',       acc.PersonDepartment);
        addLine(lines, 'Privacy Hold',     acc.HasPrivacyHold ? 'Yes' : 'No');
        addLine(lines, 'Status',           acc.IsActive ? 'Active' : 'Inactive');
        addLine(lines, 'Interaction Sent', acc.sent_Interaction__c ? 'Yes' : 'No');
        addLine(lines, 'Billing Address',
            buildAddress(acc.BillingStreet, acc.BillingCity,
                         acc.BillingState, acc.BillingPostalCode, acc.BillingCountry));
        addLine(lines, 'Mailing Address',
            buildAddress(acc.PersonMailingStreet, acc.PersonMailingCity,
                         acc.PersonMailingState, acc.PersonMailingPostalCode, acc.PersonMailingCountry));
        addLine(lines, 'Industry',         acc.Industry);
        addLine(lines, 'Account Type',     acc.Type);
        addLine(lines, 'Rating',           acc.Rating);
        addLine(lines, 'Account Source',   acc.AccountSource);
        addLine(lines, 'Ownership',        acc.Ownership);
        addLine(lines, 'Website',          acc.Website);
        addLine(lines, 'Source System ID', acc.SourceSystemIdentifier);
        addLine(lines, 'Annual Revenue',
            acc.AnnualRevenue != null ? formatAmount(acc.AnnualRevenue) : null);
        addLine(lines, 'Employees',
            acc.NumberOfEmployees != null ? String.valueOf(acc.NumberOfEmployees) : null);
        if (String.isNotBlank(acc.Description)) {
            lines.add('Description            : ' + acc.Description);
        }
        addLine(lines, 'Record Created',
            acc.CreatedDate != null ? acc.CreatedDate.format() : null);
        addLine(lines, 'Last Modified',
            acc.LastModifiedDate != null ? acc.LastModifiedDate.format() : null);

        lines.add('\nFINANCIAL ACCOUNTS & HOLDINGS');
        lines.add('----------------------------------');
        appendFinancialSection(lines, acc, '  ');

        lines.add('\n==========================================');
        lines.add('  END OF SUMMARY');
        lines.add('==========================================');

        return String.join(lines, '\n');
    }

    /* ─────────────────────────────────────────────
       FINANCIAL SECTION  (shared by individual + each household member)
    ───────────────────────────────────────────── */
    private static void appendFinancialSection(List<String> lines, Account acc, String indent) {

        Set<Id> faIds = new Set<Id>();
        List<FinancialAccountParty> parties = new List<FinancialAccountParty>();

        // Strategy 1: FinancialAccountParty
        List<FinancialAccountParty> partyResults = [
            SELECT Id, Name, FinancialAccountId, Role,
                   IsRoleActive, RoleStartDate, RoleEndDate
            FROM FinancialAccountParty
            WHERE AccountId = :acc.Id
            ORDER BY RoleStartDate DESC NULLS LAST
        ];
        if (!partyResults.isEmpty()) {
            parties = partyResults;
            for (FinancialAccountParty p : parties) {
                if (p.FinancialAccountId != null) faIds.add(p.FinancialAccountId);
            }
        }

        // Strategy 2: SecuritiesHolding.PrimaryOwnerId
        Map<Id, List<SecuritiesHolding>> directHoldingsMap = new Map<Id, List<SecuritiesHolding>>();
        if (faIds.isEmpty()) {
            List<SecuritiesHolding> directHoldings = [
                SELECT Id, Name, FinancialAccountId, FinancialSecurityId,
                       AssetClass, Sector, Share_Name__c,
                       Shares, PurchasePrice, Price, MarketValue, GainLoss,
                       InvestmentStartDate, InvestmentEndDate, CurrencyIsoCode
                FROM SecuritiesHolding
                WHERE PrimaryOwnerId = :acc.Id
                ORDER BY MarketValue DESC NULLS LAST
            ];
            if (!directHoldings.isEmpty()) {
                for (SecuritiesHolding sh : directHoldings) {
                    Id groupKey = sh.FinancialAccountId != null ? sh.FinancialAccountId : acc.Id;
                    if (sh.FinancialAccountId != null) faIds.add(sh.FinancialAccountId);
                    if (!directHoldingsMap.containsKey(groupKey)) {
                        directHoldingsMap.put(groupKey, new List<SecuritiesHolding>());
                    }
                    directHoldingsMap.get(groupKey).add(sh);
                }
            }
        }

        // Fetch FinancialAccount records
        Map<Id, FinancialAccount> faMap = new Map<Id, FinancialAccount>();
        if (!faIds.isEmpty()) {
            for (FinancialAccount fa : [
                SELECT Id, Name, FinancialAccountNumber, Type, Status,
                       TotalOutstandingAmount, PrincipalAmount, CreditLimit,
                       InterestRate, AmountDue, DownPaymentAmount,
                       OpeningDate, ClosingDate, MaturityDate, PaymentDueDate,
                       IsManaged, CurrencyIsoCode
                FROM FinancialAccount
                WHERE Id IN :faIds
                ORDER BY OpeningDate DESC NULLS LAST
            ]) {
                faMap.put(fa.Id, fa);
            }
        }

        // Fetch SecuritiesHoldings via FinancialAccountId
        Map<Id, List<SecuritiesHolding>> holdingsMap = directHoldingsMap;
        if (holdingsMap.isEmpty() && !faIds.isEmpty()) {
            for (SecuritiesHolding sh : [
                SELECT Id, Name, FinancialAccountId, FinancialSecurityId,
                       AssetClass, Sector, Share_Name__c,
                       Shares, PurchasePrice, Price, MarketValue, GainLoss,
                       InvestmentStartDate, InvestmentEndDate, CurrencyIsoCode
                FROM SecuritiesHolding
                WHERE FinancialAccountId IN :faIds
                ORDER BY MarketValue DESC NULLS LAST
            ]) {
                if (!holdingsMap.containsKey(sh.FinancialAccountId)) {
                    holdingsMap.put(sh.FinancialAccountId, new List<SecuritiesHolding>());
                }
                holdingsMap.get(sh.FinancialAccountId).add(sh);
            }
        }

        if (faMap.isEmpty() && holdingsMap.isEmpty()) {
            lines.add(indent + 'No financial accounts or securities holdings found.');
            return;
        }

        Set<Id> allFaIds = new Set<Id>();
        allFaIds.addAll(faMap.keySet());
        allFaIds.addAll(holdingsMap.keySet());

        Map<Id, List<FinancialAccountParty>> partiesByFA = new Map<Id, List<FinancialAccountParty>>();
        for (FinancialAccountParty p : parties) {
            if (!partiesByFA.containsKey(p.FinancialAccountId)) {
                partiesByFA.put(p.FinancialAccountId, new List<FinancialAccountParty>());
            }
            partiesByFA.get(p.FinancialAccountId).add(p);
        }

        Integer faIdx = 1;
        for (Id faId : allFaIds) {
            FinancialAccount fa = faMap.get(faId);
            List<FinancialAccountParty> faParts = partiesByFA.containsKey(faId)
                                                  ? partiesByFA.get(faId)
                                                  : new List<FinancialAccountParty>();

            lines.add(indent + '-- Account #' + faIdx++ + ' --');

            if (fa != null) {
                addLine(lines, indent + 'Account Name',    fa.Name);
                addLine(lines, indent + 'Account Number',  fa.FinancialAccountNumber);
                addLine(lines, indent + 'Type',            fa.Type);
                addLine(lines, indent + 'Status',          fa.Status);
                addLine(lines, indent + 'Outstanding Amt',
                    fa.TotalOutstandingAmount != null
                    ? fa.CurrencyIsoCode + ' ' + formatAmount(fa.TotalOutstandingAmount) : null);
                addLine(lines, indent + 'Principal Amount',
                    fa.PrincipalAmount != null
                    ? fa.CurrencyIsoCode + ' ' + formatAmount(fa.PrincipalAmount) : null);
                addLine(lines, indent + 'Credit Limit',
                    fa.CreditLimit != null
                    ? fa.CurrencyIsoCode + ' ' + formatAmount(fa.CreditLimit) : null);
                addLine(lines, indent + 'Interest Rate',
                    fa.InterestRate != null ? fa.InterestRate + '%' : null);
                addLine(lines, indent + 'Amount Due',
                    fa.AmountDue != null
                    ? fa.CurrencyIsoCode + ' ' + formatAmount(fa.AmountDue) : null);
                addLine(lines, indent + 'Opening Date',
                    fa.OpeningDate  != null ? fa.OpeningDate.format()  : null);
                addLine(lines, indent + 'Maturity Date',
                    fa.MaturityDate != null ? fa.MaturityDate.format() : null);
                addLine(lines, indent + 'Managed',         fa.IsManaged ? 'Yes' : 'No');
            }

            if (!faParts.isEmpty()) {
                lines.add(indent + 'Roles:');
                for (FinancialAccountParty p : faParts) {
                    String roleEntry = indent + '  * ' + nvl(p.Role, 'Unknown Role')
                        + ' | Active: ' + (p.IsRoleActive ? 'Yes' : 'No');
                    if (p.RoleStartDate != null) roleEntry += ' | Start: ' + p.RoleStartDate.format();
                    if (p.RoleEndDate   != null) roleEntry += ' | End: '   + p.RoleEndDate.format();
                    lines.add(roleEntry);
                }
            }

            List<SecuritiesHolding> holdings = holdingsMap.get(faId);
            if (holdings != null && !holdings.isEmpty()) {
                lines.add(indent + 'Securities Holdings:');
                Decimal totalMV = 0;
                for (SecuritiesHolding sh : holdings) {
                    lines.add(
                        indent + '  * ' + nvl(sh.Share_Name__c, nvl(sh.Name, 'N/A'))
                        + ' | Class: '   + nvl(sh.AssetClass, 'N/A')
                        + ' | Sector: '  + nvl(sh.Sector,     'N/A')
                        + ' | Shares: '  + (sh.Shares        != null ? String.valueOf(sh.Shares)                                 : 'N/A')
                        + ' | Buy: '     + (sh.PurchasePrice != null ? sh.CurrencyIsoCode + ' ' + formatAmount(sh.PurchasePrice)  : 'N/A')
                        + ' | Price: '   + (sh.Price         != null ? sh.CurrencyIsoCode + ' ' + formatAmount(sh.Price)          : 'N/A')
                        + ' | Mkt Val: ' + (sh.MarketValue   != null ? sh.CurrencyIsoCode + ' ' + formatAmount(sh.MarketValue)    : 'N/A')
                        + ' | G/L: '     + (sh.GainLoss      != null ? String.valueOf(sh.GainLoss)                                : 'N/A')
                        + ' | Start: '   + (sh.InvestmentStartDate != null ? sh.InvestmentStartDate.format() : 'N/A')
                    );
                    if (sh.MarketValue != null) totalMV += sh.MarketValue;
                }
                lines.add(indent + 'Portfolio Market Value: ' + formatAmount(totalMV));
            } else {
                lines.add(indent + 'Securities Holdings: None found.');
            }
        }
    }

    /* ─────────────────────────────────────────────
       HOUSEHOLD AGGREGATE
    ───────────────────────────────────────────── */
    private static void appendHouseholdAggregate(List<String> lines, Set<Id> memberAccountIds) {
        if (memberAccountIds.isEmpty()) {
            lines.add('  No member data to aggregate.');
            return;
        }

        Set<Id> allFaIds = new Set<Id>();
        for (FinancialAccountParty p : [
            SELECT FinancialAccountId
            FROM FinancialAccountParty
            WHERE AccountId IN :memberAccountIds
            AND FinancialAccountId != null
        ]) {
            allFaIds.add(p.FinancialAccountId);
        }
        for (SecuritiesHolding sh : [
            SELECT FinancialAccountId
            FROM SecuritiesHolding
            WHERE PrimaryOwnerId IN :memberAccountIds
            AND FinancialAccountId != null
        ]) {
            allFaIds.add(sh.FinancialAccountId);
        }

        Decimal householdTotalMV   = 0;
        Decimal householdTotalGL   = 0;
        Integer totalHoldingsCount = 0;
        Map<String, Decimal> mvBySector     = new Map<String, Decimal>();
        Map<String, Decimal> mvByAssetClass = new Map<String, Decimal>();

        List<SecuritiesHolding> allHoldings = new List<SecuritiesHolding>();
        if (!allFaIds.isEmpty()) {
            allHoldings = [
                SELECT AssetClass, Sector, MarketValue, GainLoss
                FROM SecuritiesHolding
                WHERE FinancialAccountId IN :allFaIds
            ];
        }

        // Also pick up direct holdings via PrimaryOwnerId not already covered
        for (SecuritiesHolding sh : [
            SELECT AssetClass, Sector, MarketValue, GainLoss, FinancialAccountId
            FROM SecuritiesHolding
            WHERE PrimaryOwnerId IN :memberAccountIds
        ]) {
            if (sh.FinancialAccountId == null || !allFaIds.contains(sh.FinancialAccountId)) {
                allHoldings.add(sh);
            }
        }

        for (SecuritiesHolding sh : allHoldings) {
            totalHoldingsCount++;
            if (sh.MarketValue != null) {
                householdTotalMV += sh.MarketValue;
                String sec = nvl(sh.Sector,     'Unclassified');
                String cls = nvl(sh.AssetClass, 'Unclassified');
                mvBySector.put(sec,
                    (mvBySector.containsKey(sec)     ? mvBySector.get(sec)     : 0) + sh.MarketValue);
                mvByAssetClass.put(cls,
                    (mvByAssetClass.containsKey(cls) ? mvByAssetClass.get(cls) : 0) + sh.MarketValue);
            }
            if (sh.GainLoss != null) householdTotalGL += sh.GainLoss;
        }

        lines.add('  Total Holdings     : ' + totalHoldingsCount);
        lines.add('  Total Market Value : ' + formatAmount(householdTotalMV));
        lines.add('  Total Gain / Loss  : ' + formatAmount(householdTotalGL));

        if (!mvByAssetClass.isEmpty()) {
            lines.add('\n  Breakdown by Asset Class:');
            for (String cls : mvByAssetClass.keySet()) {
                lines.add('    * ' + cls + ' : ' + formatAmount(mvByAssetClass.get(cls)));
            }
        }
        if (!mvBySector.isEmpty()) {
            lines.add('\n  Breakdown by Sector:');
            for (String sec : mvBySector.keySet()) {
                lines.add('    * ' + sec + ' : ' + formatAmount(mvBySector.get(sec)));
            }
        }
    }

    /* ─────────────────────────────────────────────
       HELPERS
    ───────────────────────────────────────────── */
    private static void addLine(List<String> lines, String label, String value) {
        if (String.isNotBlank(value)) {
            lines.add(label.rightPad(26) + ': ' + value);
        }
    }

    private static void addLinePfx(List<String> lines, String prefix, String label, String value) {
        if (String.isNotBlank(value)) {
            lines.add(prefix + label.rightPad(26) + ': ' + value);
        }
    }

    private static String buildAddress(String street, String city,
                                       String state, String zip, String country) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(street))  parts.add(street);
        if (String.isNotBlank(city))    parts.add(city);
        if (String.isNotBlank(state))   parts.add(state);
        if (String.isNotBlank(zip))     parts.add(zip);
        if (String.isNotBlank(country)) parts.add(country);
        return parts.isEmpty() ? null : String.join(parts, ', ');
    }

    private static String nvl(String value, String fallback) {
        return String.isNotBlank(value) ? value : fallback;
    }

    // Safe string cast from Object (used for SObject.get() results)
    private static String strVal(Object val) {
        return (val != null) ? String.valueOf(val) : null;
    }

    // Safe boolean cast from Object (used for SObject.get() results)
    private static Boolean boolVal(Object val) {
        if (val == null) return false;
        if (val instanceof Boolean) return (Boolean) val;
        return String.valueOf(val).equalsIgnoreCase('true');
    }

    private static String formatAmount(Decimal value) {
        if (value == null) return 'N/A';
        return value.setScale(2).toPlainString()
                    .replaceAll('(\\d)(?=(\\d{3})+\\.)', '$1,');
    }

    /* ─────────────────────────────────────────────
       CUSTOM EXCEPTION
    ───────────────────────────────────────────── */
    public class ClientNotFoundException extends Exception {}
}