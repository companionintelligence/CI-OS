import React from 'react';

const Dashboard = ({ onLogout }) => {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-gray-100 dark:bg-gray-900">
      <h1 className="text-4xl mb-4">Dashboard</h1>
      <button onClick={onLogout} className="bg-red-500 text-white p-2 rounded">Logout</button>
    </div>
  );
};

export default Dashboard;