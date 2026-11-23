import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RemindTaskVO } from '../model/RemindTask';

const DOMAIN: number = 0x0001;
const TAG: string = 'ReminderService';
/** 与 AppScope/app.json5 的 bundleName 保持一致 */
const BUNDLE_NAME: string = 'com.ricaro.medicationreminder';
const ABILITY_NAME: string = 'EntryAbility';

/**
 * 从 "2026-10-02T08:00:00" 里解析出的时分。
 */
export class HourMinute {
  hour: number = 0;
  minute: number = 0;
}

/**
 * 到点提醒。
 *
 * 用 reminderAgentManager（代理提醒）而不是自己起定时器或后台任务：
 * 代理提醒由系统托管，应用退出、被杀、手机重启后仍然有效，
 * 这是鸿蒙做「吃药提醒」的唯一正确姿势。自己起 setInterval 只在应用
 * 活着的时候有效，锁屏一会儿就没了；用长时任务保活则要一直占着
 * 后台配额，为了几个闹钟点不划算。
 *
 * 每次同步都是「先全清、再按当前待办重排」：
 * 与其维护「哪条任务对应哪个 reminderId」的映射（还得处理跨天、
 * 计划变更、后端重排时间等情况），不如把撤销交给系统一次做完，
 * 状态只有一份，就是后端下发的今日待办。
 */
export class ReminderService {
  /**
   * 确认通知开关已打开。
   *
   * 鸿蒙发本地通知不需要动态申请权限，但用户可以在设置里关掉；
   * requestEnableNotification 会弹出系统弹窗让用户确认，
   * 关掉之后再 publish 是静默失败的，所以发提醒前先确认一次。
   */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      let enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      enabled = await notificationManager.isNotificationEnabled();
      hilog.info(DOMAIN, TAG, '通知开关: %{public}s', enabled ? '已开启' : '仍关闭');
      return enabled;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, '确认通知开关失败 code=%{public}d msg=%{public}s', e.code, e.message);
      return false;
    }
  }

  /**
   * 按今日待办重排代理提醒。
   *
   * 只给「未确认、未取消、未过期、且时间还没到」的任务注册提醒——
   * 时间已经过去的再注册，会在明天同一时刻响，属于错的提醒。
   *
   * @returns 实际注册成功的条数，用于界面提示与日志核对。
   */
  static async syncTodayTasks(tasks: RemindTaskVO[]): Promise<number> {
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '清空旧提醒失败 code=%{public}d', e.code);
    }

    const now: Date = new Date();
    let published: number = 0;

    for (let i = 0; i < tasks.length; i++) {
      const task: RemindTaskVO = tasks[i];
      if (task.confirmed || task.status === 'CANCELLED' || task.status === 'EXPIRED') {
        continue;
      }
      const hm: HourMinute | null = ReminderService.parseHourMinute(task.scheduledAt);
      if (hm === null || ReminderService.isPassed(hm, now)) {
        continue;
      }
      try {
        await reminderAgentManager.publishReminder(ReminderService.buildRequest(task, hm));
        published++;
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(DOMAIN, TAG, '注册提醒失败 taskId=%{public}d code=%{public}d msg=%{public}s',
          task.id, e.code, e.message);
      }
    }

    hilog.info(DOMAIN, TAG, '今日待办 %{public}d 条，注册提醒 %{public}d 条', tasks.length, published);
    return published;
  }

  /**
   * 清空全部提醒（退出登录时调用，避免上一个账号的提醒还挂在系统里）。
   */
  static async clearAll(): Promise<void> {
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '清空提醒失败 code=%{public}d', e.code);
    }
  }

  /**
   * 组装一条代理提醒。
   *
   * daysOfWeek 取满七天使提醒每天重复：用药本来就按天循环，
   * 每天打开 App 同步时会整批重排，所以这里不需要算「下次是哪天」。
   */
  private static buildRequest(task: RemindTaskVO, hm: HourMinute): reminderAgentManager.ReminderRequestAlarm {
    const request: reminderAgentManager.ReminderRequestAlarm = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
      hour: hm.hour,
      minute: hm.minute,
      daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
      title: '该吃药了 · ' + ReminderService.formatTime(hm),
      content: task.medicineName + '  ' + task.dosagePerTime + task.dosageUnit +
        (ReminderService.mealText(task.mealRelation) === '' ? '' :
          '（' + ReminderService.mealText(task.mealRelation) + '）'),
      expiredContent: '这次服药还没有确认',
      snoozeTimes: 1,
      timeInterval: 300,
      notificationId: task.id,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      wantAgent: {
        pkgName: BUNDLE_NAME,
        abilityName: ABILITY_NAME
      },
      actionButton: [
        {
          title: '知道了',
          type: reminderAgentManager.ActionButtonType.ACTION_BUTTON_TYPE_CLOSE
        }
      ]
    };
    return request;
  }

  /**
   * "2026-10-02T08:00:00" → { hour: 8, minute: 0 }，格式不对返回 null。
   */
  private static parseHourMinute(scheduledAt: string): HourMinute | null {
    if (scheduledAt.length < 16) {
      return null;
    }
    const hour: number = Number.parseInt(scheduledAt.substring(11, 13));
    const minute: number = Number.parseInt(scheduledAt.substring(14, 16));
    if (Number.isNaN(hour) || Number.isNaN(minute)) {
      return null;
    }
    const result: HourMinute = new HourMinute();
    result.hour = hour;
    result.minute = minute;
    return result;
  }

  /**
   * 今天这个时刻是否已经过去（含前后一分钟的容差）。
   */
  private static isPassed(hm: HourMinute, now: Date): boolean {
    const nowMinutes: number = now.getHours() * 60 + now.getMinutes();
    return hm.hour * 60 + hm.minute <= nowMinutes;
  }

  private static formatTime(hm: HourMinute): string {
    const h: string = hm.hour < 10 ? '0' + hm.hour : '' + hm.hour;
    const m: string = hm.minute < 10 ? '0' + hm.minute : '' + hm.minute;
    return h + ':' + m;
  }

  private static mealText(mealRelation: number): string {
    if (mealRelation === 1) {
      return '餐前';
    }
    if (mealRelation === 2) {
      return '餐后';
    }
    if (mealRelation === 3) {
      return '晨起空腹';
    }
    if (mealRelation === 4) {
      return '睡前';
    }
    return '';
  }
}
