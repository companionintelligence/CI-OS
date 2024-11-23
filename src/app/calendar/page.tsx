import Calendar from "@/components/Calender";
import { Metadata } from "next";
import DefaultLayout from "@/components/Layouts/DefaultLayout";

export const metadata: Metadata = {
  title: "Companion Intelligence - Calendar",
  description:
    "Companion Intelligence - Calendar",
};

const CalendarPage = () => {
  return (
    <DefaultLayout>
      <Calendar />
    </DefaultLayout>
  );
};

export default CalendarPage;
