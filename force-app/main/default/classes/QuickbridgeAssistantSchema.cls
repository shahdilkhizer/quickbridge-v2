// Static catalogs ported from the deployed Quick Bridge org; no transport or persistence dependencies.
public inherited sharing class QuickbridgeAssistantSchema {
  public class Field {
    public String label; public String value; public String type; public Boolean required;
    public Boolean inboundAllowed; public Boolean outboundAllowed;
  }
  private static final Set<String> CUSTOMER_WRITABLE = new Set<String>{
        'DisplayName',
        'CompanyName',
        'GivenName',
        'MiddleName',
        'FamilyName',
        'Suffix',
        'Title',
        'AcctNum',
        'Notes',
        'Active',
        'PrimaryEmailAddr.Address',
        'PrimaryPhone.FreeFormNumber',
        'BillAddr.Line1',
        'BillAddr.City',
        'BillAddr.CountrySubDivisionCode',
        'BillAddr.PostalCode',
        'BillAddr.Country',
        'ShipAddr.Line1',
        'ShipAddr.City',
        'ShipAddr.CountrySubDivisionCode',
        'ShipAddr.PostalCode',
        'ShipAddr.Country',
        'SalesTermRef.value'
    };
  private static final Set<String> VENDOR_WRITABLE = new Set<String>{
        'DisplayName',
        'CompanyName',
        'PrintOnCheckName',
        'Title',
        'GivenName',
        'MiddleName',
        'FamilyName',
        'Suffix',
        'AcctNum',
        'Notes',
        'Active',
        'PrimaryEmailAddr.Address',
        'PrimaryPhone.FreeFormNumber',
        'AlternatePhone.FreeFormNumber',
        'Mobile.FreeFormNumber',
        'Fax.FreeFormNumber',
        'WebAddr.URI',
        'BillAddr.Line1',
        'BillAddr.City',
        'BillAddr.CountrySubDivisionCode',
        'BillAddr.PostalCode',
        'BillAddr.Country',
        'TermRef.value',
        'CurrencyRef.value',
        'TaxIdentifier',
        'Vendor1099'
    };
  public static Map<String, Field> fields(String connector, String entity, Boolean child) {
    String key = String.isBlank(entity) ? '' : entity.toLowerCase();
    if (connector == 'qbo') return getFallbackFields(entity + (child ? 'Line' : ''));
    if (connector == 'shopify') return getFallbackShopifyFieldDefinitions(child ? 'LineItem' : entity);
    if (connector == 'netsuite') {
      Map<String,String> aliases = new Map<String,String>{'inventoryitem'=>'Item','itemfulfillment'=>'Fulfillment','customerpayment'=>'Payment'};
      String canonical = aliases.containsKey(key) ? aliases.get(key) : entity;
      return getFallbackNetSuiteFieldDefinitions(canonical + (child ? 'Line' : ''));
    }
    if (connector == 'meta' && !child) {
      return getFallbackMetaFieldDefinitions(key == 'leadgen' ? 'leadad' : key == 'comment' ? 'commentattribution' : entity);
    }
    return new Map<String,Field>();
  }

  private static Map<String, Field> getFallbackFields(
    String qbEntity
  ) {
    Map<String, Field> qbFields = new Map<String, Field>();

    if (qbEntity == 'Customer') {
      addField(
        qbFields,
        'QB - DisplayName',
        'DisplayName',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - CompanyName',
        'CompanyName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - FamilyName',
        'FamilyName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - GivenName',
        'GivenName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - AcctNum',
        'AcctNum',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Email',
        'PrimaryEmailAddr.Address',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Phone',
        'PrimaryPhone.FreeFormNumber',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Billing Street',
        'BillAddr.Line1',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Billing City',
        'BillAddr.City',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Billing State/Province',
        'BillAddr.CountrySubDivisionCode',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Billing Postal Code',
        'BillAddr.PostalCode',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Billing Country',
        'BillAddr.Country',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Shipping Street',
        'ShipAddr.Line1',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Shipping City',
        'ShipAddr.City',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Shipping State/Province',
        'ShipAddr.CountrySubDivisionCode',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Shipping Postal Code',
        'ShipAddr.PostalCode',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Shipping Country',
        'ShipAddr.Country',
        'STRING',
        false
      );
      addField(qbFields, 'QB - Notes', 'Notes', 'STRING', false);
      addField(qbFields, 'QB - Balance', 'Balance', 'NUMBER', false);
      addField(
        qbFields,
        'QB - Balance With Jobs',
        'BalanceWithJobs',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Fully Qualified Name',
        'FullyQualifiedName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Print On Check Name',
        'PrintOnCheckName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Currency Name',
        'CurrencyRef.name',
        'STRING',
        false
      );
    } else if (qbEntity == 'Vendor') {
      addField(
        qbFields,
        'QB - DisplayName',
        'DisplayName',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - CompanyName',
        'CompanyName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - FamilyName',
        'FamilyName',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - GivenName',
        'GivenName',
        'STRING',
        false
      );
      addField(qbFields, 'QB - MiddleName', 'MiddleName', 'STRING', false);
      addField(qbFields, 'QB - Suffix', 'Suffix', 'STRING', false);
      addField(qbFields, 'QB - Account Number', 'AcctNum', 'STRING', false);
      addField(
        qbFields,
        'QB - Primary Email',
        'PrimaryEmailAddr.Address',
        'STRING',
        false
      );
      addField(qbFields, 'QB - Billing Street', 'BillAddr.Line1', 'STRING', false);
      addField(qbFields, 'QB - Billing City', 'BillAddr.City', 'STRING', false);
      addField(
        qbFields,
        'QB - Billing State/Province',
        'BillAddr.CountrySubDivisionCode',
        'STRING',
        false
      );
      addField(qbFields, 'QB - Billing Postal Code', 'BillAddr.PostalCode', 'STRING', false);
      addField(qbFields, 'QB - Billing Country', 'BillAddr.Country', 'STRING', false);
      addField(qbFields, 'QB - Notes', 'Notes', 'STRING', false);
      addField(qbFields, 'QB - Balance', 'Balance', 'NUMBER', false);
      addField(qbFields, 'QB - Print On Check Name', 'PrintOnCheckName', 'STRING', false);
      addField(qbFields, 'QB - Currency Name', 'CurrencyRef.name', 'STRING', false);
      addField(qbFields, 'QB - Currency Id', 'CurrencyRef.value', 'STRING', false);
      addField(qbFields, 'QB - Terms Id', 'TermRef.value', 'STRING', false);
      addField(qbFields, 'QB - Tax Identifier', 'TaxIdentifier', 'STRING', false);
      addField(qbFields, 'QB - 1099 Vendor', 'Vendor1099', 'BOOLEAN', false);
      addField(
        qbFields,
        'QB - Primary Phone',
        'PrimaryPhone.FreeFormNumber',
        'STRING',
        false
      );
    } else if (qbEntity == 'Item') {
      addField(qbFields, 'QB - Name', 'Name', 'STRING', true);
      addField(
        qbFields,
        'QB - Description',
        'Description',
        'STRING',
        false
      );
      addField(qbFields, 'QB - Sku', 'Sku', 'STRING', false);
      addField(
        qbFields,
        'QB - UnitPrice',
        'UnitPrice',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - PurchaseCost',
        'PurchaseCost',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Type',
        'Type',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - Active',
        'Active',
        'BOOLEAN',
        false
      );
      addField(
        qbFields,
        'QB - TrackQtyOnHand',
        'TrackQtyOnHand',
        'BOOLEAN',
        false
      );
      addField(
        qbFields,
        'QB - QtyOnHand',
        'QtyOnHand',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - InvStartDate',
        'InvStartDate',
        'DATE',
        false
      );
      addField(
        qbFields,
        'QB - IncomeAccountRef.value',
        'IncomeAccountRef.value',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - ExpenseAccountRef.value',
        'ExpenseAccountRef.value',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - AssetAccountRef.value',
        'AssetAccountRef.value',
        'STRING',
        false
      );
    } else if (qbEntity == 'Invoice') {
      addField(
        qbFields,
        'QB - CustomerRef.value',
        'CustomerRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - DocNumber',
        'DocNumber',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - TotalAmt',
        'TotalAmt',
        'NUMBER',
        false
      );
      addField(qbFields, 'QB - TxnDate', 'TxnDate', 'DATE', false);
      addField(
        qbFields,
        'QB - Customer Memo',
        'CustomerMemo.value',
        'STRING',
        false
      );
    } else if (qbEntity == 'CreditMemo') {
      addField(
        qbFields,
        'QB - CustomerRef.value',
        'CustomerRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - DocNumber',
        'DocNumber',
        'STRING',
        false
      );
      addField(qbFields, 'QB - TxnDate', 'TxnDate', 'DATE', false);
      addField(
        qbFields,
        'QB - TotalAmt',
        'TotalAmt',
        'NUMBER',
        false
      );
    } else if (qbEntity == 'PurchaseOrder') {
      addField(
        qbFields,
        'QB - VendorRef.value',
        'VendorRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - DocNumber',
        'DocNumber',
        'STRING',
        false
      );
      addField(qbFields, 'QB - TxnDate', 'TxnDate', 'DATE', false);
      addField(
        qbFields,
        'QB - TotalAmt',
        'TotalAmt',
        'NUMBER',
        false
      );
    } else if (qbEntity == 'TaxCode') {
      addField(qbFields, 'QB - Name', 'Name', 'STRING', true);
      addField(
        qbFields,
        'QB - Description',
        'Description',
        'STRING',
        false
      );
    } else if (qbEntity == 'InvoiceLine') {
      addField(
        qbFields,
        'QB - Product/Service ID',
        'Line.SalesItemLineDetail.ItemRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - Amount',
        'Line.Amount',
        'NUMBER',
        true
      );
      addField(
        qbFields,
        'QB - Quantity',
        'Line.SalesItemLineDetail.Qty',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Unit Price',
        'Line.SalesItemLineDetail.UnitPrice',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Description',
        'Line.Description',
        'STRING',
        false
      );
    } else if (qbEntity == 'CreditMemoLine') {
      addField(
        qbFields,
        'QB - Product/Service ID',
        'Line.SalesItemLineDetail.ItemRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - Amount',
        'Line.Amount',
        'NUMBER',
        true
      );
      addField(
        qbFields,
        'QB - Quantity',
        'Line.SalesItemLineDetail.Qty',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Unit Price',
        'Line.SalesItemLineDetail.UnitPrice',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Description',
        'Line.Description',
        'STRING',
        false
      );
    } else if (qbEntity == 'PurchaseOrderLine') {
      addField(
        qbFields,
        'QB - Product/Service ID',
        'Line.ItemBasedExpenseLineDetail.ItemRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - Amount',
        'Line.Amount',
        'NUMBER',
        true
      );
      addField(
        qbFields,
        'QB - Quantity',
        'Line.ItemBasedExpenseLineDetail.Qty',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Unit Price',
        'Line.ItemBasedExpenseLineDetail.UnitPrice',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Description',
        'Line.Description',
        'STRING',
        false
      );
    } else if (qbEntity == 'Estimate') {
      addField(
        qbFields,
        'QB - CustomerRef.value',
        'CustomerRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - DocNumber',
        'DocNumber',
        'STRING',
        false
      );
      addField(
        qbFields,
        'QB - TotalAmt',
        'TotalAmt',
        'NUMBER',
        false
      );
      addField(qbFields, 'QB - TxnDate', 'TxnDate', 'DATE', false);
      addField(
        qbFields,
        'QB - ExpirationDate',
        'ExpirationDate',
        'DATE',
        false
      );
      addField(
        qbFields,
        'QB - Customer Memo',
        'CustomerMemo.value',
        'STRING',
        false
      );
    } else if (qbEntity == 'EstimateLine') {
      addField(
        qbFields,
        'QB - Product/Service ID',
        'Line.SalesItemLineDetail.ItemRef.value',
        'STRING',
        true
      );
      addField(
        qbFields,
        'QB - Amount',
        'Line.Amount',
        'NUMBER',
        true
      );
      addField(
        qbFields,
        'QB - Quantity',
        'Line.SalesItemLineDetail.Qty',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Unit Price',
        'Line.SalesItemLineDetail.UnitPrice',
        'NUMBER',
        false
      );
      addField(
        qbFields,
        'QB - Description',
        'Line.Description',
        'STRING',
        false
      );
    }

    applyQBFieldCapabilities(qbEntity, qbFields);
    return qbFields;
  }


  private static Map<String, Field> getFallbackShopifyFieldDefinitions(
    String entity
  ) {
    Map<String, Field> fields = new Map<String, Field>();

    if (entity == 'Customer') {
      addField(fields, 'Shopify - id', 'id', 'STRING', true);
      addField(fields, 'Shopify - email', 'email', 'STRING', false);
      addField(
        fields,
        'Shopify - first_name',
        'first_name',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - last_name',
        'last_name',
        'STRING',
        true
      );
      addField(fields, 'Shopify - phone', 'phone', 'STRING', false);
      addField(
        fields,
        'Shopify - tax_exempt',
        'tax_exempt',
        'BOOLEAN',
        false
      );
      addField(fields, 'Shopify - tags', 'tags', 'STRING', false);
      addField(
        fields,
        'Shopify - total_spent',
        'total_spent',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Shopify - orders_count',
        'orders_count',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Shopify - default_address.address1',
        'default_address.address1',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - default_address.city',
        'default_address.city',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - default_address.province',
        'default_address.province',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - default_address.zip',
        'default_address.zip',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - default_address.country',
        'default_address.country',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - sms_marketing_consent.state',
        'sms_marketing_consent.state',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - sms_marketing_consent.opt_in_level',
        'sms_marketing_consent.opt_in_level',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - email_marketing_consent.state',
        'email_marketing_consent.state',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - email_marketing_consent.opt_in_level',
        'email_marketing_consent.opt_in_level',
        'STRING',
        false
      );
    } else if (entity == 'Order') {
      addField(fields, 'Shopify - id', 'id', 'STRING', false);
      addField(fields, 'Shopify - name', 'name', 'STRING', false);
      addField(
        fields,
        'Shopify - created_at',
        'created_at',
        'DATE',
        false
      );
      addField(
        fields,
        'Shopify - total_price',
        'total_price',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Shopify - total_discounts',
        'total_discounts',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Shopify - total_tax',
        'total_tax',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Shopify - financial_status',
        'financial_status',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - fulfillment_status',
        'fulfillment_status',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - payment_gateway_names',
        'payment_gateway_names',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - contact_email',
        'contact_email',
        'STRING',
        false
      );
      addField(
        fields,
        'Shopify - cancel_reason',
        'cancel_reason',
        'STRING',
        false
      );
    } else if (entity == 'Product') {
      addField(fields, 'Shopify - id', 'id', 'STRING', true);
      addField(fields, 'Shopify - title', 'title', 'STRING', true);
      addField(
        fields,
        'Shopify - status',
        'status',
        'STRING',
        false
      );
    } else if (entity == 'LineItem') {
      addField(fields, 'Shopify - id', 'id', 'STRING', false);
      addField(
        fields,
        'Shopify - quantity',
        'quantity',
        'NUMBER',
        false
      );
      addField(fields, 'Shopify - price', 'price', 'NUMBER', false);
      addField(fields, 'Shopify - sku', 'sku', 'STRING', false);
      addField(fields, 'Shopify - title', 'title', 'STRING', false);
    }

    return fields;
  }


  private static Map<String, Field> getFallbackNetSuiteFieldDefinitions(
    String entity
  ) {
    Map<String, Field> fields = new Map<String, Field>();
    if (entity == 'Customer') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Entity ID',
        'entityid',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Company Name',
        'companyname',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - First Name',
        'firstname',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Last Name',
        'lastname',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Email',
        'email',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Phone',
        'phone',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Billing City',
        'billcity',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Subsidiary',
        'subsidiary',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Currency',
        'currency',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Taxable',
        'taxable',
        'BOOLEAN',
        false
      );
      addField(
        fields,
        'NetSuite - Status',
        'entitystatus',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Last Modified Date',
        'lastmodifieddate',
        'DATETIME',
        false
      );
    } else if (entity == 'Item') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - SKU / Item ID',
        'itemid',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Display Name',
        'displayname',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Description',
        'salesdescription',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Item Type',
        'itemtype',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Base Price',
        'baseprice',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Currency',
        'currency',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Price Level',
        'pricelevel',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Tax Schedule',
        'taxschedule',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Inactive',
        'isinactive',
        'BOOLEAN',
        false
      );
      addField(
        fields,
        'NetSuite - Quantity Available',
        'quantityavailable',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Last Modified Date',
        'lastmodifieddate',
        'DATETIME',
        false
      );
    } else if (entity == 'SalesOrder') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Transaction ID',
        'tranid',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Entity',
        'entity',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Transaction Date',
        'trandate',
        'DATE',
        false
      );
      addField(
        fields,
        'NetSuite - Status',
        'status',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Total',
        'total',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Subsidiary',
        'subsidiary',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Department',
        'department',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Class',
        'class',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Location',
        'location',
        'STRING',
        false
      );
    } else if (entity == 'SalesOrderLine') {
      addField(
        fields,
        'NetSuite - Line ID',
        'line',
        'STRING',
        true
      );
      addField(fields, 'NetSuite - Item', 'item', 'STRING', true);
      addField(
        fields,
        'NetSuite - Description',
        'description',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Quantity',
        'quantity',
        'NUMBER',
        false
      );
      addField(fields, 'NetSuite - Rate', 'rate', 'NUMBER', false);
      addField(
        fields,
        'NetSuite - Amount',
        'amount',
        'NUMBER',
        false
      );
    } else if (entity == 'Invoice') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Transaction ID',
        'tranid',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Entity',
        'entity',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Transaction Date',
        'trandate',
        'DATE',
        false
      );
      addField(
        fields,
        'NetSuite - Total',
        'total',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Amount Remaining',
        'amountremaining',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Status',
        'status',
        'STRING',
        false
      );
    } else if (entity == 'InvoiceLine') {
      addField(
        fields,
        'NetSuite - Line ID',
        'line',
        'STRING',
        true
      );
      addField(fields, 'NetSuite - Item', 'item', 'STRING', true);
      addField(
        fields,
        'NetSuite - Description',
        'description',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Quantity',
        'quantity',
        'NUMBER',
        false
      );
      addField(fields, 'NetSuite - Rate', 'rate', 'NUMBER', false);
      addField(
        fields,
        'NetSuite - Amount',
        'amount',
        'NUMBER',
        false
      );
    } else if (entity == 'Payment') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Transaction ID',
        'tranid',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Customer',
        'customer',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Amount',
        'payment',
        'NUMBER',
        false
      );
      addField(
        fields,
        'NetSuite - Account',
        'account',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Applied Invoice',
        'appliedto',
        'STRING',
        false
      );
    } else if (entity == 'Fulfillment') {
      addField(
        fields,
        'NetSuite - Internal ID',
        'id',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Created From',
        'createdfrom',
        'STRING',
        true
      );
      addField(
        fields,
        'NetSuite - Tracking Number',
        'trackingnumbers',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Ship Date',
        'shipdate',
        'DATE',
        false
      );
      addField(
        fields,
        'NetSuite - Status',
        'status',
        'STRING',
        false
      );
      addField(
        fields,
        'NetSuite - Location',
        'location',
        'STRING',
        false
      );
      addField(fields, 'NetSuite - Item', 'item', 'STRING', false);
      addField(
        fields,
        'NetSuite - Quantity',
        'quantity',
        'NUMBER',
        false
      );
    }
    return fields;
  }


  private static Map<String, Field> getFallbackMetaFieldDefinitions(
    String entity
  ) {
    Map<String, Field> fields = new Map<String, Field>();
    String normalizedEntity = normalizeMetaEntity(entity);

    if (normalizedEntity == 'campaign') {
      addField(fields, 'Meta - Campaign ID', 'id', 'STRING', true);
      addField(
        fields,
        'Meta - Campaign Name',
        'name',
        'STRING',
        true
      );
      addField(
        fields,
        'Meta - Ad Account ID',
        'account_id',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Objective',
        'objective',
        'STRING',
        false
      );
      addField(fields, 'Meta - Status', 'status', 'STRING', false);
      addField(
        fields,
        'Meta - Daily Budget',
        'daily_budget',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Meta - Lifetime Budget',
        'lifetime_budget',
        'NUMBER',
        false
      );
    } else if (normalizedEntity == 'adset') {
      addField(fields, 'Meta - Ad Set ID', 'id', 'STRING', true);
      addField(
        fields,
        'Meta - Ad Set Name',
        'name',
        'STRING',
        true
      );
      addField(
        fields,
        'Meta - Campaign ID',
        'campaign_id',
        'STRING',
        true
      );
      addField(fields, 'Meta - Status', 'status', 'STRING', false);
      addField(
        fields,
        'Meta - Optimization Goal',
        'optimization_goal',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Daily Budget',
        'daily_budget',
        'NUMBER',
        false
      );
      addField(
        fields,
        'Meta - Lifetime Budget',
        'lifetime_budget',
        'NUMBER',
        false
      );
    } else if (normalizedEntity == 'ad') {
      addField(fields, 'Meta - Ad ID', 'id', 'STRING', true);
      addField(fields, 'Meta - Ad Name', 'name', 'STRING', true);
      addField(
        fields,
        'Meta - Campaign ID',
        'campaign_id',
        'STRING',
        true
      );
      addField(
        fields,
        'Meta - Ad Set ID',
        'adset_id',
        'STRING',
        true
      );
      addField(fields, 'Meta - Status', 'status', 'STRING', false);
      addField(
        fields,
        'Meta - Creative ID',
        'creative.id',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Preview Link',
        'preview_shareable_link',
        'STRING',
        false
      );
    } else if (normalizedEntity == 'leadad') {
      addField(fields, 'Meta - Lead ID', 'id', 'STRING', true);
      addField(
        fields,
        'Meta - Campaign ID',
        'campaign_id',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Ad Set ID',
        'adset_id',
        'STRING',
        false
      );
      addField(fields, 'Meta - Ad ID', 'ad_id', 'STRING', false);
      addField(
        fields,
        'Meta - Form ID',
        'form_id',
        'STRING',
        false
      );
      addField(fields, 'Meta - Email', 'email', 'STRING', false);
      addField(
        fields,
        'Meta - Phone Number',
        'phone_number',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Full Name',
        'full_name',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - First Name',
        'first_name',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Last Name',
        'last_name',
        'STRING',
        false
      );
    } else if (normalizedEntity == 'campaignmemberattribution') {
      addField(
        fields,
        'Meta - Leadgen ID',
        'leadgen_id',
        'STRING',
        true
      );
      addField(
        fields,
        'Meta - Campaign ID',
        'campaign_id',
        'STRING',
        true
      );
      addField(fields, 'Meta - Status', 'status', 'STRING', false);
    } else if (normalizedEntity == 'commentattribution') {
      addField(
        fields,
        'Meta - Comment ID',
        'comment_id',
        'STRING',
        true
      );
      addField(
        fields,
        'Meta - Post ID',
        'post_id',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Campaign ID',
        'campaign_id',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Comment Text',
        'comment_text',
        'STRING',
        false
      );
      addField(
        fields,
        'Meta - Commenter Name',
        'commenter_name',
        'STRING',
        false
      );
    } else if (normalizedEntity == 'insights') {
      addField(fields, 'Meta - Insight ID', 'id', 'STRING', true);
      addField(fields, 'Meta - Spend', 'spend', 'NUMBER', false);
      addField(
        fields,
        'Meta - Impressions',
        'impressions',
        'NUMBER',
        false
      );
      addField(fields, 'Meta - Clicks', 'clicks', 'NUMBER', false);
      addField(fields, 'Meta - Reach', 'reach', 'NUMBER', false);
      addField(
        fields,
        'Meta - Lead Actions',
        'actions.lead',
        'NUMBER',
        false
      );
    }
    return fields;
  }


  private static String normalizeObjectToken(String apiName) {
    if (String.isBlank(apiName)) {
      return '';
    }
    String token = apiName.trim();
    if (token.endsWith('__c')) {
      List<String> parts = token.split('__');
      if (parts.size() == 3) {
        token = parts[1] + '__c';
      }
      token = token.substring(0, token.length() - 3);
    }
    return token.replaceAll('[^A-Za-z0-9]', '').toLowerCase();
  }


  private static String normalizeMetaEntity(String metaObject) {
    String value = normalizeObjectToken(metaObject);
    if (value == 'campaign')
      return 'campaign';
    if (value == 'adset' || value == 'adsets')
      return 'adset';
    if (value == 'ad' || value == 'ads')
      return 'ad';
    if (value == 'lead' || value == 'leadad' || value == 'leadads')
      return 'leadad';
    if (value == 'campaignmemberattribution')
      return 'campaignmemberattribution';
    if (value == 'commentattribution')
      return 'commentattribution';
    if (value == 'insight' || value == 'insights')
      return 'insights';
    return metaObject;
  }


  private static void addField(
    Map<String, Field> fieldMap,
    String label,
    String value,
    String type,
    Boolean required
  ) {
    Field definition = new Field();
    definition.label = label;
    definition.value = value;
    definition.type = normalizeType(type);
    definition.required = required;
    definition.inboundAllowed = true;
    definition.outboundAllowed = true;
    fieldMap.put(value, definition);
  }


  private static String normalizeType(String value) {
    if (String.isBlank(value)) {
      return null;
    }
    String upperValue = value.trim().toUpperCase();
    if (
      upperValue == 'CURRENCY' ||
      upperValue == 'DOUBLE' ||
      upperValue == 'INTEGER' ||
      upperValue == 'PERCENT' ||
      upperValue == 'DECIMAL' ||
      upperValue == 'LONG' ||
      upperValue == 'NUMBER'
    ) {
      return 'NUMBER';
    }
    if (upperValue == 'DATE' || upperValue == 'DATETIME') {
      return 'DATE';
    }
    if (upperValue == 'BOOLEAN') {
      return 'BOOLEAN';
    }
    return 'STRING';
  }


  private static void applyQBFieldCapabilities(
    String qbEntity,
    Map<String, Field> definitions
  ) {
    if (definitions == null) {
      return;
    }
    for (Field definition : definitions.values()) {
      definition.inboundAllowed = true;
      definition.outboundAllowed = qbEntity == 'Customer'
        ? CUSTOMER_WRITABLE.contains(definition.value)
        : qbEntity == 'Vendor'
          ? VENDOR_WRITABLE.contains(definition.value)
          : true;
    }
  }

}