<?php
// SPDX-FileCopyrightText: 2026 civico GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later
// Test data for the event, contribution and api profiles. Prints what the test needs: IDs of
// event, contribution page, processor, amount field and option, two self-service queries, and
// the contact of the API user.
use Civi\Api4\{Contact, ContributionPage, ContributionRecur, Event, Participant, PaymentProcessor, PriceField, PriceFieldValue, PriceSet, PriceSetEntity, Role, User};

$event = Event::create(FALSE)->setValues([
  'title' => 'Test event',
  'event_type_id:name' => 'Conference',
  'start_date' => date('Y-m-d 10:00', strtotime('+1 year')),
  'is_public' => TRUE,
  'is_active' => TRUE,
  'is_online_registration' => TRUE,
  'is_monetary' => FALSE,
  'is_confirm_enabled' => FALSE,
  'allow_selfcancelxfer' => TRUE,
  'selfcancelxfer_time' => 0,
])->execute()->single();

// A registration and a recurring contribution, reached through the links their mails carry.
$attendee = Contact::create(FALSE)->setValues(['contact_type' => 'Individual', 'first_name' => 'Attendee'])->execute()->single();
$participant = Participant::create(FALSE)->setValues([
  'event_id' => $event['id'],
  'contact_id' => $attendee['id'],
  'status_id:name' => 'Registered',
  'role_id:name' => ['Attendee'],
])->execute()->single();
$selfService = "pid={$participant['id']}&cs=" . CRM_Contact_BAO_Contact_Utils::generateChecksum($attendee['id']);

$processor = PaymentProcessor::create(FALSE)->setValues([
  'name' => 'Test processor',
  'payment_processor_type_id:name' => 'Dummy',
  'user_name' => 'dummy',
  'is_active' => TRUE,
  'is_test' => FALSE,
  'domain_id' => 1,
])->execute()->single();

$page = ContributionPage::create(FALSE)->setValues([
  'title' => 'Test donation',
  'financial_type_id:name' => 'Donation',
  'payment_processor' => [$processor['id']],
  'is_pay_later' => TRUE,
  'pay_later_text' => 'Bank transfer',
  'is_active' => TRUE,
  'is_monetary' => TRUE,
  'amount_block_is_active' => TRUE,
  'is_confirm_enabled' => FALSE,
  'is_email_receipt' => FALSE,
  'currency' => 'EUR',
])->execute()->single();

// The amount choice the page form builds as a "quick config" price set.
$priceSet = PriceSet::create(FALSE)->setValues([
  'name' => 'test_donation',
  'title' => 'Test donation',
  'extends' => [CRM_Core_Component::getComponentID('CiviContribute')],
  'financial_type_id:name' => 'Donation',
  'is_quick_config' => TRUE,
])->execute()->single();
$field = PriceField::create(FALSE)->setValues([
  'price_set_id' => $priceSet['id'],
  'name' => 'contribution_amount',
  'label' => 'Amount',
  'html_type' => 'Radio',
  'is_required' => FALSE,
])->execute()->single();
foreach ([10, 25] as $amount) {
  $options[] = PriceFieldValue::create(FALSE)->setValues([
    'price_field_id' => $field['id'],
    'name' => "amount_$amount",
    'label' => "$amount",
    'amount' => $amount,
    'financial_type_id:name' => 'Donation',
  ])->execute()->single()['id'];
}
PriceSetEntity::create(FALSE)->setValues([
  'price_set_id' => $priceSet['id'],
  'entity_table' => 'civicrm_contribution_page',
  'entity_id' => $page['id'],
])->execute();

$donor = Contact::create(FALSE)->setValues(['contact_type' => 'Individual', 'first_name' => 'Donor'])->execute()->single();
$recur = ContributionRecur::create(FALSE)->setValues([
  'contact_id' => $donor['id'],
  'amount' => 10,
  'currency' => 'EUR',
  'frequency_unit' => 'month',
  'frequency_interval' => 1,
  'payment_processor_id' => $processor['id'],
  'financial_type_id:name' => 'Donation',
  'contribution_status_id:name' => 'In Progress',
  'start_date' => 'now',
])->execute()->single();
$recurLink = "crid={$recur['id']}&cid={$donor['id']}&cs=" . CRM_Contact_BAO_Contact_Utils::generateChecksum($donor['id']);

// A website that may read events through the API with its key, and do nothing else.
Role::create(FALSE)->setValues([
  'name' => 'website',
  'label' => 'Website',
  'permissions' => ['authenticate with api key', 'access CiviEvent', 'view event info'],
])->execute();
$contact = Contact::create(FALSE)->setValues([
  'contact_type' => 'Individual',
  'first_name' => 'Website',
])->execute()->single();
User::create(FALSE)->setValues([
  'username' => 'website',
  'contact_id' => $contact['id'],
  'is_active' => TRUE,
  'roles:name' => ['website'],
])->execute();

echo "{$event['id']} {$page['id']} {$processor['id']} {$field['id']} {$options[0]} $selfService $recurLink {$contact['id']}\n";
