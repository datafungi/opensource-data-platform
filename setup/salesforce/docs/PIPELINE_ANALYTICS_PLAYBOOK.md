# Pipeline Analytics Playbook

Reusable SOQL for analyzing synthetic Salesforce pipeline data in `dev-org`.

## Scope

- Org alias: `dev-org`
- Example window (Year 1): `2024-04-16` to `2025-04-16` (exclusive end)

## Core Queries

### 1) Find anchor dates

```bash
sf data query --target-org dev-org --query "SELECT MIN(CreatedDate) minCreated, MIN(CloseDate) minClose FROM Opportunity"
```

### 2) Pipeline by stage

```bash
sf data query --target-org dev-org --query "
SELECT StageName, COUNT(Id) opps, SUM(Amount) totalAmount, AVG(Probability) avgProbability
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY StageName
ORDER BY SUM(Amount) DESC"
```

### 3) Monthly trend

```bash
sf data query --target-org dev-org --query "
SELECT CALENDAR_MONTH(CloseDate) monthNum, COUNT(Id) opps, SUM(Amount) totalAmount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY CALENDAR_MONTH(CloseDate)
ORDER BY CALENDAR_MONTH(CloseDate)"
```

### 4) Closed/Won split

```bash
sf data query --target-org dev-org --query "
SELECT IsWon, IsClosed, COUNT(Id) opps, SUM(Amount) totalAmount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY IsWon, IsClosed
ORDER BY IsClosed DESC, IsWon DESC"
```

### 5) Geography mix (APAC vs US)

```bash
sf data query --target-org dev-org --query "
SELECT Account.BillingCountry country, COUNT(Id) opps, SUM(Amount) totalAmount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Account.BillingCountry
ORDER BY SUM(Amount) DESC"
```

### 6) Segment x offering

```bash
sf data query --target-org dev-org --query "
SELECT Account.Customer_Segment__c segment, Offering_Type__c offering, COUNT(Id) opps, SUM(Amount) totalAmount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Account.Customer_Segment__c, Offering_Type__c
ORDER BY Account.Customer_Segment__c, Offering_Type__c"
```

### 7) Motion x cross-sell source

```bash
sf data query --target-org dev-org --query "
SELECT Sales_Motion__c motion, Cross_Sell_From__c crossFrom, COUNT(Id) opps, SUM(Amount) totalAmount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Sales_Motion__c, Cross_Sell_From__c
ORDER BY COUNT(Id) DESC"
```

### 8) Offering mix with Expected ARR

```bash
sf data query --target-org dev-org --query "
SELECT Offering_Type__c offering, COUNT(Id) opps, SUM(Amount) amount, SUM(Expected_ARR__c) expectedARR
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Offering_Type__c"
```

## Analytical Cases

### Case 1: Cross-sell efficiency by origin motion

Business question: Which path is healthier, `Services -> SaaS` or `SaaS -> Services`?

Query A (Services -> SaaS):

```bash
sf data query --target-org dev-org --query "
SELECT IsWon, COUNT(Id) opps, COUNT_DISTINCT(AccountId) accounts, SUM(Amount) amount, SUM(Expected_ARR__c) expectedARR
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
  AND Cross_Sell_From__c = 'Services'
  AND (Offering_Type__c = 'Cross-sell SaaS' OR Offering_Type__c = 'Hybrid Expansion')
GROUP BY IsWon"
```

Query B (SaaS -> Services):

```bash
sf data query --target-org dev-org --query "
SELECT IsWon, COUNT(Id) opps, COUNT_DISTINCT(AccountId) accounts, SUM(Amount) amount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
  AND Cross_Sell_From__c = 'SaaS'
  AND Offering_Type__c = 'Cross-sell Services'
GROUP BY IsWon"
```

Interpretation:

- Compare `IsWon=true` rates by motion.
- Compare `SUM(Amount)` for near-term revenue impact.
- Compare `SUM(Expected_ARR__c)` for recurring upside.

### Case 2: Region + segment expansion prioritization

Business question: Where should GTM focus first across APAC and US?

Query A (region/segment/offering mix):

```bash
sf data query --target-org dev-org --query "
SELECT Account.Region__c region, Account.Customer_Segment__c segment, Offering_Type__c offering, COUNT(Id) opps, SUM(Amount) amount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Account.Region__c, Account.Customer_Segment__c, Offering_Type__c
ORDER BY Account.Region__c, SUM(Amount) DESC"
```

Query B (win-rate by region and motion):

```bash
sf data query --target-org dev-org --query "
SELECT Account.Region__c region, Sales_Motion__c motion, IsWon, COUNT(Id) opps, SUM(Amount) amount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Account.Region__c, Sales_Motion__c, IsWon
ORDER BY Account.Region__c, Sales_Motion__c, IsWon DESC"
```

### Case 3: Monetization model stress test

Business question: Do pricing and contract models align with effort and deal size?

Query A (usage pricing performance):

```bash
sf data query --target-org dev-org --query "
SELECT Usage_Pricing_Model__c usageModel, IsWon, COUNT(Id) opps, SUM(Amount) amount, AVG(Expected_ARR__c) avgExpectedARR
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
  AND Offering_Type__c IN ('SaaS New Logo', 'Cross-sell SaaS', 'Hybrid Expansion')
GROUP BY Usage_Pricing_Model__c, IsWon
ORDER BY Usage_Pricing_Model__c, IsWon DESC"
```

Query B (contract model vs delivery effort):

```bash
sf data query --target-org dev-org --query "
SELECT Contract_Model__c contractModel, Data_Volume_Tier__c volumeTier, COUNT(Id) opps, AVG(Implementation_Months__c) avgImplMonths, SUM(Amount) amount
FROM Opportunity
WHERE CloseDate >= 2024-04-16 AND CloseDate < 2025-04-16
GROUP BY Contract_Model__c, Data_Volume_Tier__c
ORDER BY Contract_Model__c, Data_Volume_Tier__c"
```

## Notes

- SOQL has self-semi-join limits on the same object. Prefer Account-based intersections or explicit cross-sell fields.
- For repeatable reporting, keep start/end dates parameterized and run monthly or quarterly.
