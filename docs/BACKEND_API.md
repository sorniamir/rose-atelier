# API و Edge Functions فروشگاه

این مستند قرارداد بک‌اند است. رابط سایت فعلی هنوز با این APIها یکپارچه نشده و فرم checkout داخل سایت صرفاً نمایشی است.

## پیش‌نیازها

- پروژه Supabase مستقل برای فروشگاه
- اجرای فایل migration در مسیر supabase/migrations/202610140001_store_schema.sql
- فعال بودن Supabase Auth و ساخت کاربر مدیر از مسیر Auth
- افزودن شناسه مدیر از طریق SQL Editor:

      insert into public.store_admins (user_id) values ('<auth.users UUID>');

- تنظیم secrets در Supabase Edge Functions:

      supabase secrets set ALLOWED_ORIGIN=https://your-store-domain.example STORE_CURRENCY_CODE=IRR

  SUPABASE_URL و کلیدهای لازم باید توسط runtime/تنظیمات امن پروژه در اختیار function باشند. اگر از کلیدهای جدید استفاده می‌کنید از SUPABASE_PUBLISHABLE_KEY و SUPABASE_SECRET_KEY استفاده کنید؛ در پروژه‌های قدیمی، نام‌های SUPABASE_ANON_KEY و SUPABASE_SERVICE_ROLE_KEY هم پشتیبانی شده‌اند. کلید محرمانه هرگز نباید در مرورگر یا مخزن Git قرار گیرد.

## ایجاد سفارش

Endpoint: POST /functions/v1/create-order

نیازمند Authorization: Bearer <Supabase user access token> و نشست کاربر واردشده است.

نمونه بدنه:

    {
      "customer_name": "نام مشتری",
      "customer_phone": "شماره تماس",
      "shipping_address": "نشانی کامل",
      "customer_note": "",
      "items": [
        { "product_id": "UUID محصول", "quantity": 1 }
      ]
    }

قیمت از دیتابیس خوانده می‌شود؛ مبلغ ارسالی از کلاینت پذیرفته نمی‌شود. تابع دیتابیس موجودی را در تراکنش قفل و رزرو می‌کند و سفارش را با وضعیت pending_payment ثبت می‌کند. این پاسخ به معنی پرداخت موفق نیست.

## مدیریت موجودی

Endpoint: POST /functions/v1/manage-inventory

فقط کاربر واردشده‌ای که عضویت او در public.store_admins ثبت شده مجاز است.

نمونه بدنه:

    {
      "product_id": "UUID محصول",
      "quantity_delta": 12,
      "reason": "restock",
      "note": "رسید انبار 104"
    }

علت‌های مجاز: restock، return و correction. اصلاح موجودی به یادداشت حسابرسی نیاز دارد. تغییر عدد موجودی و ثبت تاریخچه در یک تراکنش دیتابیس انجام می‌شوند.

## پرداخت واقعی هنوز جداگانه نیازمند اتصال است

هیچ نام یا کلید درگاه از طرف کارفرما ارائه نشده است. پیش از فعال‌سازی دریافت وجه باید:
1. درگاه متناسب با پذیرنده و کشور ثبت کسب‌وکار انتخاب شود.
2. Edge Function اختصاصی آغاز پرداخت، کاربر را به صفحه امن ارائه‌دهنده هدایت کند.
3. callback سمت سرور اصالت‌سنجی و با API رسمی درگاه verify شود.
4. فقط پس از verify موفق و با مرجع تراکنش قابل‌اتکا، mark_store_order_paid فراخوانی شود.
5. تابع زمان‌بندی‌شده release_expired_store_reservations برای آزادکردن رزروهای پرداخت‌نشده، با سیاست امن و پس از اتمام مهلت پرداخت اجرا شود.
6. درخواست‌های تکراری callback، لغو، مرجوعی و بازپرداخت تست شوند.

هر سه RPC حساس فقط برای نقش service_role قابل فراخوانی‌اند. Edge Functionها قبل از استفاده از کلید سرور، توکن کاربر را اعتبارسنجی می‌کنند؛ تابع مدیریتی هم نقش مدیر را از جدول سروری بررسی می‌کند. با این حال، قبل از production کد باید در پروژه واقعی deploy، با تست‌های end-to-end آزموده و توسط مالک درگاه تأیید شود.
