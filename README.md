# PeyamApp v6 — راهنمای کامل

## نصب و راه‌اندازی سریع در ترموکس

```bash
termux-setup-storage
pkg install -y unzip
cd ~
unzip ~/storage/shared/peyamapp.zip -d ~/
cd ~/peyamapp
echo 'export GMAIL_USER="youraddress@gmail.com"' >> ~/.bashrc
echo 'export GMAIL_APP_PASSWORD="yourapppasswordwithoutspaces"' >> ~/.bashrc
source ~/.bashrc
bash run-termux.sh
```

بعد از اولین اجرا، دفعات بعد فقط کافیست:
```bash
cd ~/peyamapp && node server.js
```

⚠️ کد App Password را **بدون فاصله** بگذار — گوگل آن را با فاصله نشان می‌دهد ولی خودش فاصله ندارد.

---

## چه چیزهایی در این نسخه اضافه شد

### حساب کاربری و امنیت
- ورود فقط با Gmail واقعی + کد ۷ کاراکتری واقعی به ایمیل
- بخش **Account** کامل: Add account, Passkey (کد امنیتی ۷ کاراکتری که خود سیستم می‌سازد), Email address, Two-step verification, Security notifications (روشن/خاموش), Username, Change email, Logout

### مخاطبین و گروه‌ها
- دکمه **+** پایین صفحه حالا یک منو دارد: **New Contact** (نام، فامیلی، یوزرنیم یا ایمیل) و **New Group**
- ساخت گروه: انتخاب اعضا از مخاطبین یا جستجو → نام/عکس گروه → تنظیم پرمیشن‌های گروه (ارسال پیام، ویرایش اطلاعات گروه، افزودن عضو، نمایش تاریخچه به عضو جدید، تایید عضو جدید توسط ادمین)

### حریم خصوصی (Privacy)
- Last seen online, Profile picture, About, Links: هرکدام Everyone / My contacts / Nobody
- ایمیل شخص همیشه برای مخاطبین قابل مشاهده است (مثل شماره در واتساپ)
- Status: انتخاب دستی این‌که کدام مخاطب‌ها Status شما را ببینند
- Read receipts، Disappearing messages، Allow camera effects: هرکدام روشن/خاموش
- **App Lock**: قفل کل اپ با پسکد + امکان biometric (اختیاری)
- **Chat Lock**: قفل کردن یک چت خاص جداگانه

### فضای ذخیره و دیتا (Storage and Data)
- نمایش مصرف فضا، مصرف شبکه، Use less data for calls، کیفیت آپلود/دانلود (HD یا SD)

### زبان و درباره
- App Language، و صفحه PeyamApp (تاریخچه، لایسنس، Legend Team)

### چت
- ارسال واقعی عکس، ویدیو، فایل، **پیام صوتی** (نگه‌داشتن دکمه میکروفون) و ایموجی (پیکر مخصوص نوشتن پیام)
- ری‌اکشن ایموجی روی پیام‌ها با نگه‌داشتن انگشت (long-press) — حداقل ۷ ایموجی سریع
- ادیت پیام، حذف برای خودم، حذف برای همه (فقط فرستنده)
- ساعت واقعی پیام بر اساس ساعت محلی گوشی
- تیک‌ها: ✓ خاکستری (ارسال شد) → ✓✓ نارنجی (رسید ولی نخوانده) → ✓✓ آبی (خوانده شد)
- کلیک روی عکس پروفایل یا عکس چت برای دیدن تمام‌صفحه
- سه‌نقطه چت: View contact, Chat theme, Block, Disappearing messages, Mute notifications, Lock chat, Clear chat
- تماس صوتی و **تصویری** واقعی (WebRTC) — اجازه میکروفون/دوربین فقط از Settings → Account → App Permissions گرفته می‌شود، نه وسط چت

### تب‌های پایین صفحه (مثل واتساپ، بروزتر)
Updates → Calls → Chats → PeyamApp

---

## نکات مهم فنی
- داده‌ها در `data.json` کنار `server.js` ذخیره می‌شوند — با ری‌استارت سرور از دست نمی‌روند
- فایل‌های آپلودی (عکس/ویدیو/فایل/صدا) در `public/uploads/`
- برای دسترسی از گوشی‌های دیگر در همان شبکه، سرور باید HTTPS باشد (گواهی خودامضا که `run-termux.sh` می‌سازد) وگرنه مرورگرها اجازه میکروفون/دوربین/نوتیفیکیشن نمی‌دهند مگر روی `localhost`
- برای هر کاربر جدید کافیست ایمیل جیمیل خودش را وارد کند — نیازی به App Password ندارد؛ App Password فقط برای اکانتی است که سرور با آن ایمیل می‌فرستد
