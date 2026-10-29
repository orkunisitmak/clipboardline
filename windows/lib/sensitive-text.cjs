'use strict';

// Match macOS SensitiveText. A copy that is only a payment card number or IBAN
// never enters history; text that merely contains one stays exact and admitted,
// because long digit runs in prose are usually order or tracking numbers.
const CARD_DIGITS={min:13,max:19},IBAN_LENGTH={min:15,max:34},IBAN_MODULUS=97,IBAN_CHECK_REMAINDER=1;

function compact(value){
  const text=value.replace(/[\p{White_Space}-]/gu,'');
  return /^[A-Za-z0-9]+$/.test(text)?text.toUpperCase():null;
}
function cardNumber(text){
  if(!/^\d+$/.test(text)||text.length<CARD_DIGITS.min||text.length>CARD_DIGITS.max)return false;
  let sum=0;
  for(let offset=0;offset<text.length;offset++){
    let digit=Number(text[text.length-1-offset]);
    if(offset%2===1){digit*=2;if(digit>9)digit-=9;}
    sum+=digit;
  }
  return sum%10===0;
}
function iban(text){
  if(text.length<IBAN_LENGTH.min||text.length>IBAN_LENGTH.max||!/^[A-Z]{2}\d{2}/.test(text))return false;
  // ISO 13616: move the country and check digits to the end, map A=10…Z=35, then mod 97.
  let remainder=0;
  for(const character of text.slice(4)+text.slice(0,4)){
    const value=parseInt(character,36);
    remainder=(remainder*(value>9?100:10)+value)%IBAN_MODULUS;
  }
  return remainder===IBAN_CHECK_REMAINDER;
}
function paymentIdentifier(value){
  const text=compact(value);
  return !!text&&(cardNumber(text)||iban(text));
}

module.exports={paymentIdentifier};
